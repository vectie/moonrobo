#include <moonbit.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif
static moonbit_bytes_t text_result(const char* s) {
  const size_t n=strlen(s);moonbit_bytes_t result=moonbit_make_bytes((int32_t)n,0);memcpy(result,s,n);return result;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_aligned_convert_usd(moonbit_bytes_t library,moonbit_bytes_t source,moonbit_bytes_t output,int32_t collision) {
  typedef int (*convert_fn)(const char*,const char*,int);
  typedef const char* (*error_fn)(void);
#if defined(_WIN32)
  HMODULE handle=LoadLibraryA((const char*)library);
  if(!handle)return text_result("cannot load native USD converter library");
  convert_fn convert=(convert_fn)GetProcAddress(handle,"mr_aligned_convert_usd");
  error_fn error=(error_fn)GetProcAddress(handle,"mr_aligned_usd_error");
#else
  void* handle=dlopen((const char*)library,RTLD_NOW|RTLD_LOCAL);
  if(!handle)return text_result(dlerror());
  convert_fn convert=(convert_fn)dlsym(handle,"mr_aligned_convert_usd");
  error_fn error=(error_fn)dlsym(handle,"mr_aligned_usd_error");
#endif
  moonbit_bytes_t result;
  if(!convert||!error)result=text_result("native USD converter ABI symbols missing");
  else if(convert((const char*)source,(const char*)output,collision))result=text_result("");
  else result=text_result(error());
#if defined(_WIN32)
  FreeLibrary(handle);
#else
  dlclose(handle);
#endif
  return result;
}
