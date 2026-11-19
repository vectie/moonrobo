#include <moonbit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
typedef struct {
 void *module;
 int (*version)(void);const char* (*error)(void);int (*open)(const char*,const char*);
 void (*release)(void*);void* (*import_module)(const char*);void* (*from_json)(const char*);
 const char* (*json)(void*);const char* (*string)(void*);
 void* (*attr)(void*,const char*);int (*has_attr)(void*,const char*);int (*set_attr)(void*,const char*,void*);
 void* (*item)(void*,void*);int (*set_item)(void*,void*,void*);
 void* (*call)(void*,void* const*,int,void*);int64_t (*length)(void*);int (*is_instance)(void*,void*);uint64_t (*identity)(void*);
 char error_text[2048];
} Session;
typedef struct {Session* session;void* value;char error[2048];} Value;
static moonbit_bytes_t bytes(const char* text){size_t n=strlen(text);if(n>INT32_MAX)return moonbit_make_bytes(0,0);moonbit_bytes_t result=moonbit_make_bytes((int)n,0);memcpy(result,text,n);return result;}
static void value_cleanup(void* data){Value* value=data;if(value->value&&value->session&&value->session->release)value->session->release(value->value);}
static Value* box(Session* session,void* raw){Value* value=moonbit_make_external_object(value_cleanup,sizeof(Value));memset(value,0,sizeof(*value));value->session=session;value->value=raw;if(!raw)snprintf(value->error,sizeof(value->error),"%s",session->error());return value;}
static void check_value(Value* value){snprintf(value->error,sizeof(value->error),"%s",value->session->error());}
MOONBIT_FFI_EXPORT Session* mr_mbt_apic_py_open(const unsigned char* path,const unsigned char* program,const unsigned char* site){
 // Session/library/interpreter stay alive for the process; PyValue finalizers may
 // run after the command releases its own Session reference.
 Session* s=calloc(1,sizeof(Session));
 if(!s)abort();s->module=dlopen((const char*)path,RTLD_NOW|RTLD_GLOBAL);
 if(!s->module){snprintf(s->error_text,sizeof(s->error_text),"%s",dlerror());return s;}
#define LOAD(field,symbol) do{*(void**)(&s->field)=dlsym(s->module,symbol);if(!s->field){snprintf(s->error_text,sizeof(s->error_text),"missing offline authoring ABI: %s",symbol);return s;}}while(0)
 LOAD(version,"mr_apic_py_api_version");LOAD(error,"mr_apic_py_error");LOAD(open,"mr_apic_py_open");LOAD(release,"mr_apic_py_release");LOAD(import_module,"mr_apic_py_import");LOAD(from_json,"mr_apic_py_from_json");LOAD(json,"mr_apic_py_json");LOAD(string,"mr_apic_py_string");LOAD(attr,"mr_apic_py_attr");LOAD(has_attr,"mr_apic_py_has_attr");LOAD(set_attr,"mr_apic_py_set_attr");LOAD(item,"mr_apic_py_item");LOAD(set_item,"mr_apic_py_set_item");LOAD(call,"mr_apic_py_call");LOAD(length,"mr_apic_py_length");LOAD(is_instance,"mr_apic_py_is_instance");LOAD(identity,"mr_apic_py_identity");
#undef LOAD
 if(s->version()!=1)strcpy(s->error_text,"unsupported offline authoring ABI version");
 else if(!s->open((const char*)program,(const char*)site))snprintf(s->error_text,sizeof(s->error_text),"%s",s->error());
 return s;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_mbt_apic_py_session_error(Session* s){return bytes(s->error_text);}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_mbt_apic_py_error(Value* v){return bytes(v->error);}
MOONBIT_FFI_EXPORT Value* mr_mbt_apic_py_import(Session* s,const unsigned char* name){return box(s,s->import_module((const char*)name));}
MOONBIT_FFI_EXPORT Value* mr_mbt_apic_py_value(Session* s,const unsigned char* text){return box(s,s->from_json((const char*)text));}
MOONBIT_FFI_EXPORT Value* mr_mbt_apic_py_attr(Value* v,const unsigned char* name){return box(v->session,v->session->attr(v->value,(const char*)name));}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_py_has_attr(Value* v,const unsigned char* name){int r=v->session->has_attr(v->value,(const char*)name);check_value(v);return r;}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_py_set_attr(Value* v,const unsigned char* name,Value* other){int r=v->session->set_attr(v->value,(const char*)name,other->value);check_value(v);return r;}
MOONBIT_FFI_EXPORT Value* mr_mbt_apic_py_item(Value* v,Value* key){return box(v->session,v->session->item(v->value,key->value));}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_py_set_item(Value* v,Value* key,Value* other){int r=v->session->set_item(v->value,key->value,other->value);check_value(v);return r;}
MOONBIT_FFI_EXPORT Value* mr_mbt_apic_py_call(Value* fn,Value** args,Value* kw){
 int n=Moonbit_array_length(args);void** raw=n?malloc((size_t)n*sizeof(void*)):NULL;
 if(n&&!raw){Value* result=box(fn->session,NULL);strcpy(result->error,"authoring argument allocation failed");return result;}
 for(int i=0;i<n;i++)raw[i]=args[i]->value;
 void* result=fn->session->call(fn->value,raw,n,kw->value);free(raw);return box(fn->session,result);
}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_mbt_apic_py_json(Value* v){const char* text=v->session->json(v->value);check_value(v);if(strlen(text)>INT32_MAX){strcpy(v->error,"vendor JSON exceeds MoonBit byte-array capacity");return bytes("");}return bytes(text);}
MOONBIT_FFI_EXPORT moonbit_bytes_t mr_mbt_apic_py_string(Value* v){const char* text=v->session->string(v->value);check_value(v);if(strlen(text)>INT32_MAX){strcpy(v->error,"vendor text exceeds MoonBit byte-array capacity");return bytes("");}return bytes(text);}
MOONBIT_FFI_EXPORT int64_t mr_mbt_apic_py_length(Value* v){int64_t n=v->session->length(v->value);check_value(v);return n;}
MOONBIT_FFI_EXPORT int32_t mr_mbt_apic_py_is_instance(Value* v,Value* type){int r=v->session->is_instance(v->value,type->value);check_value(v);return r;}
MOONBIT_FFI_EXPORT uint64_t mr_mbt_apic_py_identity(Value* v){return v->session->identity(v->value);}
