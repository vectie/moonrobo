# Actor deployment plan moved to LunaKine

The selected plan is now
[LunaKine actor deployment and LunaFlux LLM integration](LUNAKINE_DEPLOYMENT_PLAN.md).

LunaKine is a separate `lunakine` actor-runtime repository for Ascend inference.
LunaFlux handles LLM inference. MoonRobo retains LibTorch/CUDA training, portable
actor export, skill supervision, and E1 control. The earlier proposal to add
actor execution to LunaFlux is superseded.
