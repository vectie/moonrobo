///|
/// All commands remain explicit offline operations. Static checks never call
/// a preparation algorithm, upload a buffer, compile CUDA or create an artifact.
pub(all) struct FinalizeRequest {
  request : @finalizer.CommandRequest
  output : String
} derive(FromJson)

///|
pub(all) struct FactorizationRequest {
  request : @factorization.CommandRequest
  output : String
} derive(FromJson)

///|
/// Independent resolved shape/contact storage; original rigid request stays
/// unchanged. This is never a declaration of complete Newton construction.
pub(all) struct CollisionFinalizeRequest {
  request : @finalizer.CollisionRequest
  output : String
} derive(FromJson)

///|
pub(all) struct ConvergenceRequest {
  request : @convergence.CommandRequest
  output : String
} derive(FromJson, ToJson)

///|
pub(all) struct SetConstantsRequest {
  request : @set_constants.CommandRequest
  output : String
} derive(FromJson, ToJson)

///|
pub async fn prepare_finalize(request : FinalizeRequest) -> Json {
  @finalizer.finalize_artifact(request.request, request.output)
}

///|
pub async fn prepare_collision_finalize(
  request : CollisionFinalizeRequest,
) -> Json {
  @finalizer.collision_artifact(request.request, request.output)
}

///|
pub async fn prepare_factorization(request : FactorizationRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("factorization preparation requires fresh output")
  }
  let result = @factorization.execute(request.request)
  write_fragment(
    request.output,
    "moonrobo-sparse-factorization-fragment.v1",
    {
      "operation": request.request.operation.to_json(),
      "parameters": request.request.parameters,
    },
    result,
  )
}

///|
pub async fn prepare_convergence(request : ConvergenceRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("convergence preparation requires fresh output")
  }
  let result = @convergence.prepare(request.request)
  write_fragment(
    request.output,
    "moonrobo-linesearch-convergence-fragment.v1",
    request.request.to_json(),
    result,
  )
}

///|
pub async fn prepare_set_constants(request : SetConstantsRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("reference constants preparation requires fresh output")
  }
  let result = @set_constants.prepare_set_constants(request.request)
  write_fragment(
    request.output,
    "moonrobo-reference-rigid-constants-fragment.v1",
    request.request.to_json(),
    result,
  )
}
