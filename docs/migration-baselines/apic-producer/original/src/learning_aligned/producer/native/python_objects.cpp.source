// Offline SDK authoring bridge. No PyRun, eval, exec, source-string kernels,
// subprocesses, or physics substitutes. All numerical work belongs to the
// explicitly installed, pinned upstream IsaacLab/Newton/Warp objects.
#include <Python.h>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <climits>
#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif
namespace {
thread_local std::string error_text, result_text;
std::mutex initialization;
std::string active_program;
std::string active_site;
bool ready=false;
struct Gil {PyGILState_STATE state;Gil():state(PyGILState_Ensure()){}~Gil(){PyGILState_Release(state);}};
void clear(){error_text.clear();}
void capture_error(const char* fallback){
 if(!PyErr_Occurred()){error_text=fallback;return;}
 PyObject *type=nullptr,*value=nullptr,*trace=nullptr;PyErr_Fetch(&type,&value,&trace);PyErr_NormalizeException(&type,&value,&trace);
 PyObject* text=PyObject_Str(value?value:(type?type:Py_None));
 const char* utf8=text?PyUnicode_AsUTF8(text):nullptr;error_text=utf8?utf8:fallback;
 Py_XDECREF(text);Py_XDECREF(type);Py_XDECREF(value);Py_XDECREF(trace);PyErr_Clear();
}
bool module_allowed(const char* name){
 for(const char* prefix:{"isaaclab","isaaclab_newton","newton","warp","mujoco","mujoco_warp","numpy","pxr","importlib.metadata","builtins","sys"}){
  size_t n=std::strlen(prefix);if(std::strncmp(prefix,name,n)==0&&(name[n]==0||name[n]=='.'))return true;
 }return false;
}
PyObject* json_function(const char* name){PyObject* module=PyImport_ImportModule("json");if(!module)return nullptr;PyObject* fn=PyObject_GetAttrString(module,name);Py_DECREF(module);return fn;}
bool remember_unicode(PyObject* text){
 Py_ssize_t length=0;const char* utf8=PyUnicode_AsUTF8AndSize(text,&length);
 if(!utf8){capture_error("UTF-8 conversion failed");return false;}
 if(length<0||length>INT32_MAX){error_text="vendor text exceeds MoonBit byte-array capacity";return false;}
 if(std::memchr(utf8,0,static_cast<size_t>(length))){error_text="embedded NUL in vendor text is unsupported by the authoring ABI";return false;}
 result_text.assign(utf8,static_cast<size_t>(length));return true;
}
}
extern "C" EXPORT int mr_apic_py_api_version(){return 1;}
extern "C" EXPORT const char* mr_apic_py_error(){return error_text.c_str();}
extern "C" EXPORT int mr_apic_py_open(const char* program,const char* site_packages){
 clear();std::lock_guard<std::mutex> lock(initialization);
 if(!program||!program[0]){error_text="explicit SDK Python executable path is required";return 0;}
 if(Py_IsInitialized()){
  if(!ready){error_text="previous CPython setup failed; restart the authoring process";return 0;}
  if(active_program!=program||active_site!=(site_packages?site_packages:"")){error_text="authoring process already owns a different Python runtime/site-packages configuration";return 0;}return 1;
 }
 PyConfig config;PyConfig_InitPythonConfig(&config);config.parse_argv=0;config.install_signal_handlers=0;
 PyStatus status=PyConfig_SetBytesString(&config,&config.program_name,program);
 if(!PyStatus_Exception(status))status=PyConfig_SetBytesString(&config,&config.executable,program);
 if(!PyStatus_Exception(status))status=Py_InitializeFromConfig(&config);
 if(PyStatus_Exception(status)){error_text=status.err_msg?status.err_msg:"CPython initialization failed";PyConfig_Clear(&config);return 0;}
 PyConfig_Clear(&config);
 if(site_packages&&site_packages[0]){
  PyObject* path=PySys_GetObject("path");PyObject* item=PyUnicode_FromString(site_packages);
  if(!path||!item||PyList_Insert(path,0,item)<0){Py_XDECREF(item);capture_error("SDK site-packages path could not be configured");PyEval_SaveThread();return 0;}
  Py_DECREF(item);
 }
 // Never finalize: upstream modules own native CUDA contexts, pools and threads.
 active_program=program;active_site=site_packages?site_packages:"";ready=true;
 PyEval_SaveThread();return 1;
}
extern "C" EXPORT void mr_apic_py_release(void* value){if(value&&Py_IsInitialized()){Gil gil;Py_DECREF(static_cast<PyObject*>(value));}}
extern "C" EXPORT void* mr_apic_py_import(const char* name){clear();Gil gil;if(!module_allowed(name)){error_text="module outside offline SDK allowlist";return nullptr;}PyObject* result=PyImport_ImportModule(name);if(!result)capture_error("vendor import failed");return result;}
extern "C" EXPORT void* mr_apic_py_from_json(const char* text){clear();Gil gil;PyObject* fn=json_function("loads");PyObject* arg=PyUnicode_FromString(text);PyObject* result=fn&&arg?PyObject_CallFunctionObjArgs(fn,arg,nullptr):nullptr;Py_XDECREF(fn);Py_XDECREF(arg);if(!result)capture_error("JSON value construction failed");return result;}
extern "C" EXPORT const char* mr_apic_py_json(void* value){clear();Gil gil;PyObject* fn=json_function("dumps");PyObject* text=fn?PyObject_CallFunctionObjArgs(fn,static_cast<PyObject*>(value),nullptr):nullptr;Py_XDECREF(fn);if(!text){capture_error("object is not plain JSON data");return "";}remember_unicode(text);Py_DECREF(text);return error_text.empty()?result_text.c_str():"";}
extern "C" EXPORT const char* mr_apic_py_string(void* value){clear();Gil gil;PyObject* text=PyObject_Str(static_cast<PyObject*>(value));if(!text){capture_error("object string conversion failed");return "";}remember_unicode(text);Py_DECREF(text);return error_text.empty()?result_text.c_str():"";}
extern "C" EXPORT void* mr_apic_py_attr(void* object,const char* name){clear();Gil gil;if(!std::strcmp(name,"eval")||!std::strcmp(name,"exec")||!std::strcmp(name,"compile")||!std::strcmp(name,"__code__")){error_text="source execution is unavailable in authoring bridge";return nullptr;}PyObject* result=PyObject_GetAttrString(static_cast<PyObject*>(object),name);if(!result)capture_error("vendor attribute unavailable");return result;}
extern "C" EXPORT int mr_apic_py_has_attr(void* object,const char* name){clear();Gil gil;PyObject* result=PyObject_GetAttrString(static_cast<PyObject*>(object),name);if(result){Py_DECREF(result);return 1;}if(PyErr_ExceptionMatches(PyExc_AttributeError)){PyErr_Clear();return 0;}capture_error("attribute query failed");return -1;}
extern "C" EXPORT int mr_apic_py_set_attr(void* object,const char* name,void* value){clear();Gil gil;int result=PyObject_SetAttrString(static_cast<PyObject*>(object),name,static_cast<PyObject*>(value));if(result)capture_error("vendor attribute write failed");return result;}
extern "C" EXPORT void* mr_apic_py_item(void* object,void* key){clear();Gil gil;PyObject* result=PyObject_GetItem(static_cast<PyObject*>(object),static_cast<PyObject*>(key));if(!result)capture_error("vendor item unavailable");return result;}
extern "C" EXPORT int mr_apic_py_set_item(void* object,void* key,void* value){clear();Gil gil;int result=PyObject_SetItem(static_cast<PyObject*>(object),static_cast<PyObject*>(key),static_cast<PyObject*>(value));if(result)capture_error("vendor item write failed");return result;}
extern "C" EXPORT void* mr_apic_py_call(void* callable,void* const* args,int count,void* kwargs){
 clear();Gil gil;if(count<0){error_text="negative argument count";return nullptr;}
 PyObject* tuple=PyTuple_New(count);if(!tuple){capture_error("argument tuple allocation failed");return nullptr;}
 for(int i=0;i<count;i++){PyObject* item=static_cast<PyObject*>(args[i]);Py_INCREF(item);PyTuple_SET_ITEM(tuple,i,item);}
 PyObject* kw=static_cast<PyObject*>(kwargs);if(kw==Py_None)kw=nullptr;
 PyObject* result=PyObject_Call(static_cast<PyObject*>(callable),tuple,kw);Py_DECREF(tuple);if(!result)capture_error("vendor call failed");return result;
}
extern "C" EXPORT int64_t mr_apic_py_length(void* value){clear();Gil gil;Py_ssize_t n=PyObject_Length(static_cast<PyObject*>(value));if(n<0)capture_error("object has no length");return static_cast<int64_t>(n);}
extern "C" EXPORT int mr_apic_py_is_instance(void* value,void* type){clear();Gil gil;int result=PyObject_IsInstance(static_cast<PyObject*>(value),static_cast<PyObject*>(type));if(result<0)capture_error("instance query failed");return result;}
extern "C" EXPORT uint64_t mr_apic_py_identity(void* value){return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(value));}
