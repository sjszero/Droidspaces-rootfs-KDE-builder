/* zink-test.c -- GLX render + pixel readback probe for the FEX RootFS zink stack.
 *
 * It deliberately uses only dlopen/dlsym: the RootFS has no -devel libraries, so
 * nothing is linked at build time. It checks three things that matter, in order:
 * a GLX context can be created, a rendered pixel comes back with the colour that
 * was asked for, and 60 frames go out fast enough to prove the GPU is doing the
 * work rather than a software path.
 *
 * Build (aarch64 host, x86-64 target -- note the gcc-toolchain must point INTO
 * the sysroot, otherwise clang finds the host's aarch64 crtbegin.o and fails):
 *   S=/opt/x86-dev-rootfs
 *   clang -target x86_64-linux-gnu --sysroot=$S --gcc-toolchain=$S/usr \
 *         -fuse-ld=lld -O1 -o zink-test64 zink-test.c -ldl
 *
 * Run (env.sh in the zink tree carries the two library variables):
 *   DISPLAY=:0 LD_LIBRARY_PATH=/opt/zink/lib \
 *     LIBGL_DRIVERS_PATH=/opt/zink/lib/dri FEX ./zink-test64
 *
 * Expected output on Adreno 750:
 *   GL_RENDERER = zink Vulkan 1.4(Turnip Adreno (TM) 750 (MESA_TURNIP))
 *   pixel check: PASS
 *   rendered 60 frames in 1.015 s -> 59.1 fps
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef struct _XDisplay Display;
typedef unsigned long XID;
typedef XID GLXDrawable, GLXContext;
typedef struct { int visualid; void* visual; int screen; int depth; int c_class; } XVisualInfo;
typedef unsigned char GLubyte;
typedef unsigned int GLuint, GLenum, GLbitfield;
typedef int GLint, GLsizei;
typedef float GLclampf;

#define GLX_RGBA 4
#define GLX_RED_SIZE 8
#define GLX_GREEN_SIZE 9
#define GLX_BLUE_SIZE 10
#define GLX_DOUBLEBUFFER 5
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_DEPTH_BUFFER_BIT 0x100

int main(void){
    void* x11 = dlopen("libX11.so.6", RTLD_NOW|RTLD_GLOBAL);
    void* gl  = dlopen("libGL.so.1", RTLD_NOW|RTLD_GLOBAL);
    if(!x11 || !gl){ printf("dlopen failed: %s\n", dlerror()); return 1; }
    Display* (*XOpenDisplay)(const char*) = dlsym(x11, "XOpenDisplay");
    XID (*XCreateSimpleWindow)(Display*, XID, int,int,unsigned,unsigned,unsigned,unsigned long,unsigned long) = dlsym(x11, "XCreateSimpleWindow");
    XID (*XDefaultRootWindow)(Display*) = dlsym(x11, "XDefaultRootWindow");
    int (*XMapWindow)(Display*, XID) = dlsym(x11, "XMapWindow");
    int (*XSync)(Display*, int) = dlsym(x11, "XSync");
    void* (*glXChooseVisual)(Display*, int, int*) = dlsym(gl, "glXChooseVisual");
    void* (*glXCreateContext)(Display*, XVisualInfo*, void*, int) = dlsym(gl, "glXCreateContext");
    int (*glXMakeCurrent)(Display*, GLXDrawable, void*) = dlsym(gl, "glXMakeCurrent");
    void (*glXSwapBuffers)(Display*, GLXDrawable) = dlsym(gl, "glXSwapBuffers");
    void* (*glXGetProcAddressARB)(const GLubyte*) = dlsym(gl, "glXGetProcAddressARB");
    if(!XOpenDisplay||!glXChooseVisual||!glXCreateContext||!glXMakeCurrent||!glXGetProcAddressARB){ printf("missing GPU entry points\n"); return 2; }

    Display* dpy = XOpenDisplay(NULL);
    if(!dpy){ printf("cannot open display\n"); return 3; }
    int attribs[] = { GLX_RGBA, GLX_RED_SIZE,8, GLX_GREEN_SIZE,8, GLX_BLUE_SIZE,8, GLX_DOUBLEBUFFER, 0 };
    XVisualInfo* vi = glXChooseVisual(dpy, 0, attribs);
    if(!vi){ printf("glXChooseVisual failed\n"); return 4; }
    void* ctx = glXCreateContext(dpy, vi, NULL, 1);
    if(!ctx){ printf("glXCreateContext failed\n"); return 5; }
    XID win = XCreateSimpleWindow(dpy, XDefaultRootWindow(dpy), 0,0, 320,240, 0, 0, 0);
    XMapWindow(dpy, win); XSync(dpy, 0);
    if(!glXMakeCurrent(dpy, win, ctx)){ printf("glXMakeCurrent failed\n"); return 6; }

    void (*ClearColor)(GLclampf,GLclampf,GLclampf,GLclampf) = glXGetProcAddressARB((const GLubyte*)"glClearColor");
    void (*Clear)(GLbitfield) = glXGetProcAddressARB((const GLubyte*)"glClear");
    void (*Finish)(void) = glXGetProcAddressARB((const GLubyte*)"glFinish");
    void (*ReadPixels)(GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,void*) = glXGetProcAddressARB((const GLubyte*)"glReadPixels");
    const GLubyte* (*GetString)(GLenum) = glXGetProcAddressARB((const GLubyte*)"glGetString");
    if(!ClearColor||!Clear||!ReadPixels||!GetString){ printf("missing GL entry points\n"); return 7; }
    printf("GL_VENDOR   = %s\n", GetString(0x1F00));
    printf("GL_RENDERER = %s\n", GetString(0x1F01));
    printf("GL_VERSION  = %s\n", GetString(0x1F02));

    ClearColor(0.25f, 0.50f, 0.75f, 1.0f);
    Clear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    if(Finish) Finish();
    glXSwapBuffers(dpy, win);
    unsigned char px[4] = {0,0,0,0};
    ReadPixels(160,120,1,1,0x1908,0x1401,px);   /* GL_RGBA, GL_UNSIGNED_BYTE */
    printf("pixel at (160,120) = %u,%u,%u,%u  (expect ~64,128,191,255)\n", px[0],px[1],px[2],px[3]);
    int ok = (px[0] > 40 && px[0] < 90 && px[1] > 100 && px[1] < 155 && px[2] > 160);
    printf("pixel check: %s\n", ok ? "PASS" : "FAIL");

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    const int frames = 60;
    for(int i=0;i<frames;i++){
        ClearColor((float)(i%10)/10.0f, 0.4f, 0.6f, 1.0f);
        Clear(GL_COLOR_BUFFER_BIT);
        glXSwapBuffers(dpy, win);
    }
    if(Finish) Finish();
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec)/1e9;
    printf("rendered %d frames in %.3f s -> %.1f fps\n", frames, dt, frames/dt);
    return ok ? 0 : 8;
}
