#include <moonbit.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#if !defined(_WIN32)
#include <dlfcn.h>
#endif
typedef struct {void* lib;void* hull;const char*(*error)(void*);const uint8_t*(*points)(void*,size_t*);const uint8_t*(*indices)(void*,size_t*);int(*joggled)(void*);void(*close)(void*);char failure[1024];} HullHandle;
static void finish(HullHandle* h){if(h->hull&&h->close)h->close(h->hull);h->hull=NULL;
#if !defined(_WIN32)
 if(h->lib)dlclose(h->lib);
#endif
 h->lib=NULL;}
static void finalized(void* p){finish((HullHandle*)p);}
static moonbit_bytes_t copy(const uint8_t* p,size_t n){if(n>INT32_MAX)n=0;moonbit_bytes_t out=moonbit_make_bytes((int32_t)n,0);if(n)memcpy(out,p,n);return out;}
MOONBIT_FFI_EXPORT HullHandle* moonrobo_hull_open(moonbit_bytes_t adapter,moonbit_bytes_t library,moonbit_bytes_t points,int maximum){
 HullHandle* h=(HullHandle*)moonbit_make_external_object(finalized,sizeof(HullHandle));memset(h,0,sizeof(*h));
#if defined(_WIN32)
 snprintf(h->failure,sizeof(h->failure),"Qhull adapter currently requires POSIX");
#else
 if(!Moonbit_array_length(adapter)||!Moonbit_array_length(library)||memchr(adapter,0,Moonbit_array_length(adapter))||memchr(library,0,Moonbit_array_length(library))){snprintf(h->failure,sizeof(h->failure),"explicit NUL-free hull library paths required");return h;}
 h->lib=dlopen((const char*)adapter,RTLD_NOW|RTLD_LOCAL);if(!h->lib){snprintf(h->failure,sizeof(h->failure),"cannot load explicit hull adapter");return h;}
 int(*abi)(void)=(int(*)(void))dlsym(h->lib,"mr_convex_hull_abi");
 void*(*open)(const char*,const uint8_t*,size_t,int)=(void*(*)(const char*,const uint8_t*,size_t,int))dlsym(h->lib,"mr_convex_hull_open");
 h->error=(const char*(*)(void*))dlsym(h->lib,"mr_convex_hull_error");h->close=(void(*)(void*))dlsym(h->lib,"mr_convex_hull_close");
 h->points=(const uint8_t*(*)(void*,size_t*))dlsym(h->lib,"mr_convex_hull_points");h->indices=(const uint8_t*(*)(void*,size_t*))dlsym(h->lib,"mr_convex_hull_indices");h->joggled=(int(*)(void*))dlsym(h->lib,"mr_convex_hull_joggled");
 if(!abi||!open||!h->error||!h->close||!h->points||!h->indices||!h->joggled||abi()!=1){snprintf(h->failure,sizeof(h->failure),"incompatible native hull adapter ABI");return h;}
 h->hull=open((const char*)library,points,(size_t)Moonbit_array_length(points),maximum);if(!h->hull)snprintf(h->failure,sizeof(h->failure),"native hull owner allocation failed");
#endif
 return h;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_hull_error(HullHandle* h){const char* s=h->failure[0]?h->failure:h->hull&&h->error?h->error(h->hull):"hull is closed";return copy((const uint8_t*)s,strlen(s));}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_hull_points(HullHandle* h){size_t n=0;const uint8_t* p=h->hull&&h->points?h->points(h->hull,&n):NULL;return copy(p,n);}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_hull_indices(HullHandle* h){size_t n=0;const uint8_t* p=h->hull&&h->indices?h->indices(h->hull,&n):NULL;return copy(p,n);}
MOONBIT_FFI_EXPORT int moonrobo_hull_joggled(HullHandle* h){return h->hull&&h->joggled?h->joggled(h->hull):0;}
MOONBIT_FFI_EXPORT void moonrobo_hull_close(HullHandle* h){finish(h);}
