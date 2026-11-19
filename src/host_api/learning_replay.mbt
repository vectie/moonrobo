///|
fn learning_replay_parts(path : String) -> Array[String]? {
  let prefix = learning_experiments_path() + "/"
  guard path.has_prefix(prefix) else { return None }
  let parts = path[prefix.length():]
    .split("/")
    .map(part => part.to_owned())
    .to_array()
  guard parts.length() >= 2 &&
    !parts[0].is_empty() &&
    parts[0]
    .iter()
    .all(c => {
      c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '-' || c == '_'
    }) else {
    return None
  }
  Some(parts)
}

///|
pub fn learning_replay_response(
  root : String,
  path : String,
) -> HostApiResponse {
  guard learning_replay_parts(path) is Some([id, "replay"]) else {
    return error_response(404, "not-found", path, "Expected experiment/replay")
  }
  match @moondata_learning.read_replay(moondata_root_for_robobook(root), id) {
    Ok(value) => json_response(200, value)
    Err(message) => {
      let unavailable = message.contains("learning-replay-unavailable:")
      error_response(
        if unavailable {
          404
        } else {
          409
        },
        if unavailable {
          "learning-replay-unavailable"
        } else {
          "learning-replay-invalid"
        },
        path,
        message,
      )
    }
  }
}

///|
/// Binary assets require the desktop transport's byte response. The route is
/// selected by segment, never by an arbitrary path supplied by an artifact.
pub fn is_learning_replay_asset_path(path : String) -> Bool {
  learning_replay_parts(path) is Some([_, "replay-assets", ..])
}

///|
pub fn learning_replay_asset_response(
  root : String,
  path : String,
) -> Result[@moondata_learning.ReplayAsset, HostApiResponse] {
  guard learning_replay_parts(path) is Some([id, "replay-assets", digest]) else {
    return Err(
      error_response(
        404, "not-found", path, "Expected experiment/replay-assets/sha256",
      ),
    )
  }
  guard digest.length() == 64 &&
    digest.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) else {
    return Err(
      error_response(
        400, "invalid-replay-asset", path, "Expected a lowercase SHA-256 digest",
      ),
    )
  }
  match
    @moondata_learning.read_replay_asset(
      moondata_root_for_robobook(root),
      id,
      digest,
    ) {
    Ok(asset) => Ok(asset)
    Err(message) =>
      Err(
        error_response(
          if message.contains("unavailable:") {
            404
          } else {
            409
          },
          "learning-replay-asset-unavailable",
          path,
          message,
        ),
      )
  }
}
