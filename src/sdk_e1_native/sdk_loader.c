#include <moonbit.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
typedef struct {void *library;char error[1024];double values[172];int(*init)(char *,int);int(*capture)(double *,char *,int);int(*publish)(double,double,int,int,char *,int);} Controller;
/* HighController starts SDK-owned threads and exposes no shutdown operation.
 * Keep the module loaded for process lifetime: unloading live code is unsafe. */
static void cleanup(void *p){(void)p;}
static moonbit_bytes_t bytes(const char *s){int n=strlen(s);moonbit_bytes_t b=moonbit_make_bytes(n,0);memcpy(b,s,n);return b;}
MOONBIT_FFI_EXPORT Controller *moonrobo_sdk_open(const unsigned char *path){
 Controller *c=moonbit_make_external_object(cleanup,sizeof(Controller));memset(c,0,sizeof(*c));
 c->library=dlopen((const char *)path,RTLD_NOW|RTLD_LOCAL);if(!c->library){snprintf(c->error,sizeof(c->error),"%s",dlerror());return c;}
 *(void **)(&c->init)=dlsym(c->library,"moonrobo_e1_init");*(void **)(&c->capture)=dlsym(c->library,"moonrobo_e1_capture");*(void **)(&c->publish)=dlsym(c->library,"moonrobo_e1_publish");
 if(!c->init||!c->capture||!c->publish){strcpy(c->error,"SDK adapter missing moonrobo_e1 C ABI symbols");return c;}
 if(c->init(c->error,sizeof(c->error))!=0 && !c->error[0])strcpy(c->error,"SDK initialization failed");return c;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_sdk_error(Controller *c){return bytes(c->error);}
MOONBIT_FFI_EXPORT int32_t moonrobo_sdk_capture(Controller *c){return c->capture(c->values,c->error,sizeof(c->error));}
MOONBIT_FFI_EXPORT double moonrobo_sdk_value(Controller *c,int32_t i){return c->values[i];}
MOONBIT_FFI_EXPORT int32_t moonrobo_sdk_publish(Controller *c,double v,double h,int32_t a,int32_t d){return c->publish(v,h,a,d,c->error,sizeof(c->error));}
