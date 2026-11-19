///|
async fn send_learning_replay_asset(
  conn : @http.ServerConnection,
  method_ : @http.RequestMethod,
  root : String,
  path : String,
) -> Unit {
  guard method_ is Get || method_ is Head else {
    send_text_status(conn, 405, "Method Not Allowed", "Method Not Allowed\n")
    return
  }
  match @host_api.learning_replay_asset_response(root, path) {
    Err(response) => {
      conn.send_response(response.status, reason_text(response.status), extra_headers={
        "Content-Type": response.content_type,
        "X-Content-Type-Options": "nosniff",
      })
      if !(method_ is Head) {
        conn.write(response.body)
      }
    }
    Ok(asset) => {
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": asset.content_type,
        "ETag": "\"" + asset.checksum + "\"",
        "Cache-Control": "private, max-age=31536000, immutable",
        "X-Content-Type-Options": "nosniff",
      })
      if !(method_ is Head) {
        conn.write(asset.bytes)
      }
    }
  }
  conn.end_response()
}
