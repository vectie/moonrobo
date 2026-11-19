#ifndef MOONROBO_PREPARED_JSON_WRITER_HPP
#define MOONROBO_PREPARED_JSON_WRITER_HPP
#include <cmath>
#include <iomanip>
#include <locale>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
namespace mr_json {
inline std::string text(const std::string& s) {
  std::string out="\"";
  const char* hex="0123456789abcdef";
  for(unsigned char c:s) {
    if(c=='"'||c=='\\'){out+='\\';out+=char(c);}
    else if(c<32){out+="\\u00";out+=hex[c>>4];out+=hex[c&15];}
    else out+=char(c);
  }
  return out+'"';
}
template<class T> std::string number(T value) {
  if(!std::isfinite(static_cast<double>(value))) throw std::runtime_error("nonfinite model metadata");
  std::ostringstream out;out.imbue(std::locale::classic());out<<std::setprecision(17)<<value;return out.str();
}
inline std::string boolean(bool value){return value?"true":"false";}
inline std::string list(const std::vector<std::string>& values) {
  std::string out="[";bool first=true;
  for(const auto& value:values){if(!first)out+=',';first=false;out+=value;}
  return out+']';
}
template<class T> std::string array(const T* values,size_t count) {
  std::vector<std::string> rows;rows.reserve(count);
  for(size_t i=0;i<count;++i)rows.push_back(number(values[i]));return list(rows);
}
inline std::string object(std::initializer_list<std::pair<std::string,std::string>> fields) {
  std::string out="{";bool first=true;
  for(const auto& field:fields){if(!first)out+=',';first=false;out+=text(field.first)+':'+field.second;}
  return out+'}';
}
}
#endif
