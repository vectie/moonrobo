///|
pub(all) struct CatalogEntry {
  artifact_kind : String
  artifact_id : String
  manifest_path : String
  status : String
  summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn catalog_entry(
  artifact_kind : String,
  artifact_id : String,
  manifest_path : String,
  status? : String = "",
  summary? : String = "",
) -> CatalogEntry {
  { artifact_kind, artifact_id, manifest_path, status, summary }
}

///|
pub(all) struct MoonDataCatalog {
  catalog_id : String
  root : String
  generated_at_ms : Int64
  entry_count : Int
  entries : Array[CatalogEntry]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn moondata_catalog(
  root : String,
  generated_at_ms : Int64,
  entries : Array[CatalogEntry],
  catalog_id? : String = "catalog",
) -> MoonDataCatalog {
  { catalog_id, root, generated_at_ms, entry_count: entries.length(), entries }
}

///|
pub fn entry_ref(entry : CatalogEntry) -> MoonDataRef {
  moondata_ref(
    entry.artifact_kind,
    entry.artifact_id,
    entry.manifest_path,
    entry.summary,
  )
}

///|
pub fn catalog_refs(catalog : MoonDataCatalog) -> Array[MoonDataRef] {
  let refs : Array[MoonDataRef] = []
  for entry in catalog.entries {
    refs.push(entry_ref(entry))
  }
  refs
}
