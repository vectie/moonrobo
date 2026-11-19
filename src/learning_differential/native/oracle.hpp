#pragma once
#include <ATen/ATen.h>
#include <map>
#include <string>
namespace moonrobo_diff {
using Tensors = std::map<std::string,at::Tensor>;
// All data and initialization arrive explicitly. No fixture is fabricated and
// no implicit constructor RNG is permitted in this numerical oracle.
void learning_oracle(const std::string& operation,const Tensors& input,Tensors& output);
void mathematical_oracle(const std::string& operation,const Tensors& input,Tensors& output);
}
