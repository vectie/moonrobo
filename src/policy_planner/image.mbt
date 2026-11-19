///|
pub(all) enum ImageEncoding {
  Png
  Jpeg
} derive(Debug, Eq)

///|
pub extend ImageEncoding with @debug.Debug::{to_repr}

///|
pub extend ImageEncoding with Eq::{not_equal, equal}

///|
/// Immutable encoded observation. The planner transports PNG/JPEG bytes; image
/// decoding and model preprocessing remain in LunaFlux. Capture freshness and
/// physical camera calibration belong to the caller's observation adapter.
pub struct ImageObservation {
  priv data : Bytes
  priv encoding : ImageEncoding
  priv source : String
}

///|
/// Checks declared wire format/extent, not complete image validity. LunaFlux's
/// bounded decoder remains authoritative. Source is a human-readable view ID,
/// never a path or URL to fetch.
pub fn ImageObservation::from_encoded(
  data : Bytes,
  source~ : String,
) -> Self raise {
  guard !data.is_empty() &&
    data.length() <= 8388608 &&
    !source.trim().is_empty() &&
    source.length() <= 128 else {
    fail("invalid planner image observation")
  }
  let encoding = if data.has_prefix(b"\x89PNG\r\n\x1a\n") {
    Png
  } else if data.has_prefix(b"\xff\xd8\xff") {
    Jpeg
  } else {
    fail("planner image observation requires PNG or JPEG bytes")
  }
  { data, encoding, source: source.trim().to_owned(), }
}

///|
pub fn ImageObservation::encoding(self : Self) -> ImageEncoding {
  self.encoding
}

///|
pub fn ImageObservation::source(self : Self) -> String {
  self.source
}

///|
pub fn ImageObservation::byte_count(self : Self) -> Int32 {
  self.data.length()
}

///|
fn ImageObservation::data_uri(self : Self) -> String {
  let prefix = match self.encoding {
    Png => "data:image/png;base64,"
    Jpeg => "data:image/jpeg;base64,"
  }
  prefix + @base64.encode(self.data[:])
}

///|
fn user_content(
  task : String,
  images : ArrayView[ImageObservation],
) -> Json raise {
  if images.is_empty() {
    return Json(task.trim().to_owned())
  }
  guard images.length() <= 8 else {
    fail("too many planner image observations")
  }
  let mut encoded_bytes = 0L
  for image in images {
    encoded_bytes += (image.data.length().to_int64() + 2L) / 3L * 4L
    guard encoded_bytes < 16777216L else {
      fail("planner images exceed HTTP body budget")
    }
  }
  let content : Array[Json] = [
    { "type": "text", "text": Json(task.trim().to_owned()) },
  ]
  for image in images {
    content.push({
      "type": "text",
      "text": Json("Observation source: " + image.source),
    })
    content.push({
      "type": "image_url",
      "image_url": { "url": Json(image.data_uri()), "detail": "high" },
    })
  }
  Json(content)
}
