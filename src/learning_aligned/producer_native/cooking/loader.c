#include <moonbit.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "native/mesh_api.h"
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif
typedef struct {
  void* library;
  void* mesh;
  const char* (*error)(void*);
  uint64_t (*id)(void*);
  void (*refit)(void*,const uint8_t*,size_t);
  void (*close)(void*);
  char failure[1024];
  uint32_t leases;
  void* context_owner;
} MeshResource;
typedef struct { MeshResource* resource; char failure[1024]; } MeshHandle;
static void destroy_resource(MeshResource* h){
  if(h->mesh&&h->close)h->close(h->mesh);h->mesh=NULL;
  if(h->library){
#if defined(_WIN32)
    FreeLibrary((HMODULE)h->library);
#else
    dlclose(h->library);
#endif
    h->library=NULL;
  }
  if(h->context_owner){void* owner=h->context_owner;h->context_owner=NULL;moonbit_decref(owner);}
}
static void finish(MeshHandle* h){
  MeshResource* r=h->resource;h->resource=NULL;
  if(r&&--r->leases==0){destroy_resource(r);free(r);}
}
static void finalized(void* p){finish((MeshHandle*)p);}
static void* symbol(MeshResource* h,const char* name){
#if defined(_WIN32)
  void* p=(void*)GetProcAddress((HMODULE)h->library,name);
#else
  void* p=dlsym(h->library,name);
#endif
  if(!p)snprintf(h->failure,sizeof(h->failure),"missing native host mesh adapter symbol: %s",name);
  return p;
}
static int clean(moonbit_bytes_t b){return Moonbit_array_length(b)>0&&!memchr(b,0,(size_t)Moonbit_array_length(b));}
MOONBIT_FFI_EXPORT MeshHandle* moonrobo_host_mesh_open(moonbit_bytes_t adapter,moonbit_bytes_t library,
 moonbit_bytes_t points,moonbit_bytes_t velocities,moonbit_bytes_t indices,moonbit_bytes_t groups,
 int constructor,int leaf,int winding){
  MeshHandle* token=(MeshHandle*)moonbit_make_external_object(finalized,sizeof(MeshHandle));memset(token,0,sizeof(*token));
  MeshResource* h=(MeshResource*)calloc(1,sizeof(MeshResource));
  if(!h){snprintf(token->failure,sizeof(token->failure),"mesh resource allocation failed");return token;}
  token->resource=h;h->leases=1;
  if(!clean(adapter)||!clean(library)){snprintf(h->failure,sizeof(h->failure),"explicit NUL-free adapter/Warp path required");return token;}
#if defined(_WIN32)
  h->library=(void*)LoadLibraryA((const char*)adapter);
#else
  h->library=dlopen((const char*)adapter,RTLD_NOW|RTLD_LOCAL);
#endif
  if(!h->library){snprintf(h->failure,sizeof(h->failure),"cannot load explicit host mesh adapter");return token;}
  int(*abi)(void)=(int(*)(void))symbol(h,"mr_host_mesh_abi");
  void*(*open_mesh)(const char*,const uint8_t*,size_t,const uint8_t*,size_t,const uint8_t*,size_t,const uint8_t*,size_t,int,int,int)=
    (void*(*)(const char*,const uint8_t*,size_t,const uint8_t*,size_t,const uint8_t*,size_t,const uint8_t*,size_t,int,int,int))symbol(h,"mr_host_mesh_open");
  h->error=(const char*(*)(void*))symbol(h,"mr_host_mesh_error");
  h->id=(uint64_t(*)(void*))symbol(h,"mr_host_mesh_id");
  h->refit=(void(*)(void*,const uint8_t*,size_t))symbol(h,"mr_host_mesh_refit_points");
  h->close=(void(*)(void*))symbol(h,"mr_host_mesh_close");
  if(h->failure[0])return token;
  if(abi()!=1){snprintf(h->failure,sizeof(h->failure),"unsupported native host mesh adapter ABI");return token;}
  h->mesh=open_mesh((const char*)library,points,(size_t)Moonbit_array_length(points),
    velocities,(size_t)Moonbit_array_length(velocities),indices,(size_t)Moonbit_array_length(indices),
    groups,(size_t)Moonbit_array_length(groups),constructor,leaf,winding);
  if(!h->mesh)snprintf(h->failure,sizeof(h->failure),"native host mesh owner allocation failed");
  return token;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_host_mesh_error(MeshHandle* token){
  MeshResource* h=token->resource;
  const char* error=token->failure[0]?token->failure:!h?"host mesh lease is closed":h->failure[0]?h->failure:h->error&&h->mesh?h->error(h->mesh):"host mesh is unavailable";
  size_t n=error?strlen(error):0;if(n>1048576)n=1048576;
  moonbit_bytes_t b=moonbit_make_bytes((int32_t)n,0);if(n)memcpy(b,error,n);return b;
}
MOONBIT_FFI_EXPORT uint64_t moonrobo_host_mesh_id(MeshHandle* token){MeshResource* h=token->resource;return h&&!h->failure[0]&&h->mesh&&h->id?h->id(h->mesh):0;}
MOONBIT_FFI_EXPORT void moonrobo_host_mesh_refit(MeshHandle* token,moonbit_bytes_t points){
  MeshResource* h=token->resource;if(h&&!h->failure[0]&&h->mesh&&h->refit)h->refit(h->mesh,points,(size_t)Moonbit_array_length(points));
}
MOONBIT_FFI_EXPORT void moonrobo_host_mesh_close(MeshHandle* h){finish(h);}
// Every clone is a separately finalized lease. Dropping a clone without an
// explicit close cannot leave a phantom logical share pinning the resource.
MOONBIT_FFI_EXPORT MeshHandle* moonrobo_host_mesh_share(MeshHandle* token){
 MeshHandle* out=(MeshHandle*)moonbit_make_external_object(finalized,sizeof(MeshHandle));memset(out,0,sizeof(*out));
 MeshResource* h=token->resource;
 if(!h||h->failure[0]||h->leases==UINT32_MAX){snprintf(out->failure,sizeof(out->failure),"cannot retain unavailable mesh resource");return out;}
 ++h->leases;out->resource=h;return out;
}
// The MoonBit context token is transferred, not borrowed. Keep its opaque
// wrapper alive until native mesh/device teardown has completed.
MOONBIT_FFI_EXPORT void moonrobo_mesh_context_owner(MeshHandle* token,void* owner){
 MeshResource* h=token->resource;
 if(!h||h->context_owner){moonbit_decref(owner);snprintf(token->failure,sizeof(token->failure),"mesh context owner already set or closed");return;}h->context_owner=owner;
}
MOONBIT_FFI_EXPORT void moonrobo_mesh_make_device(MeshHandle* token,uint64_t context,uint64_t stream,int constructor,int leaf){
 MeshResource* h=token->resource;if(!h||h->failure[0]||!h->mesh)return;
 void(*fn)(void*,uint64_t,uint64_t,int,int)=(void(*)(void*,uint64_t,uint64_t,int,int))symbol(h,"mr_host_mesh_make_device");
 if(fn)fn(h->mesh,context,stream,constructor,leaf);
}
MOONBIT_FFI_EXPORT uint64_t moonrobo_mesh_device_id(MeshHandle* token){
 MeshResource* h=token->resource;if(!h||h->failure[0]||!h->mesh)return 0;
 uint64_t(*fn)(void*)=(uint64_t(*)(void*))symbol(h,"mr_host_mesh_device_id");return fn?fn(h->mesh):0;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_mesh_sample(MeshHandle* token,moonbit_bytes_t points,int mode,float maximum,float threshold){
 MeshResource* h=token->resource;
 int32_t n=Moonbit_array_length(points);moonbit_bytes_t out=moonbit_make_bytes(n/3,0);
 if(!h||h->failure[0]||!h->mesh)return out;
 void(*fn)(void*,const uint8_t*,size_t,int,float,float,uint8_t*,size_t)=(void(*)(void*,const uint8_t*,size_t,int,float,float,uint8_t*,size_t))symbol(h,"mr_host_mesh_sample");
 if(fn)fn(h->mesh,points,(size_t)n,mode,maximum,threshold,out,(size_t)(n/3));return out;
}
MOONBIT_FFI_EXPORT void moonrobo_mesh_velocities(MeshHandle* token,moonbit_bytes_t values){
 MeshResource* h=token->resource;if(!h||h->failure[0]||!h->mesh)return;
 void(*fn)(void*,const uint8_t*,size_t)=(void(*)(void*,const uint8_t*,size_t))symbol(h,"mr_host_mesh_refit_velocities");if(fn)fn(h->mesh,values,(size_t)Moonbit_array_length(values));
}
MOONBIT_FFI_EXPORT void moonrobo_mesh_gradients(MeshHandle* token,int operation){
 MeshResource* h=token->resource;if(!h||h->failure[0]||!h->mesh)return;
 void(*fn)(void*)=(void(*)(void*))symbol(h,operation==0?"mr_host_mesh_enable_gradients":"mr_host_mesh_zero_gradients");if(fn)fn(h->mesh);
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_mesh_gradient_snapshot(MeshHandle* token,int device,int velocity,int size){
 moonbit_bytes_t bytes=moonbit_make_bytes(size>=0?size:0,0);MeshResource* h=token->resource;
 if(!h||h->failure[0]||!h->mesh||size<0)return bytes;
 void(*fn)(void*,int,int,uint8_t*,size_t)=(void(*)(void*,int,int,uint8_t*,size_t))symbol(h,"mr_host_mesh_gradient_snapshot");if(fn)fn(h->mesh,device,velocity,bytes,(size_t)size);return bytes;
}
