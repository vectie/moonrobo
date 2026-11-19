///|
pub(all) struct TrialSummary {
  trials : Int32
  falls : Int32
  mean_survival_s : Double
  mean_joint_rmse_rad : Double
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LearningCandidate {
  seed : Int32
  selected_update : Int32
  baseline : TrialSummary
  candidate : TrialSummary
  survival_delta_s : Double
  producer_qualified : Bool
  checkpoint_ref : @data.DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LearningPayload {
  relative_path : String
  data_ref : @data.DataRef
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LearningPhysics {
  format : String
  experiment_id : String
  seed : Int32
  data_ref : @data.DataRef
  report : Json
  evaluation_mode : String?
  original_duration_s : Double?
  followup : Json?
  physical_execution_allowed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct LearningExperiment {
  format : String
  experiment_id : String
  source_id : String
  imported_at_ms : Int64
  evidence_class : String
  physical_execution_allowed : Bool
  candidates : Array[LearningCandidate]
  payloads : Array[LearningPayload]
} derive(Debug, Eq, ToJson, FromJson)

///|
priv struct PolicyRun {
  seed : Int32
  selected_update : Int32
  baseline : TrialSummary
  candidate : TrialSummary
  qualifies : Bool
  checkpoint : String
  latest_checkpoint : String
} derive(FromJson)

///|
priv struct PolicyReport {
  format : String
  runs : Array[PolicyRun]
} derive(FromJson)

///|
priv struct DynamicsRun {
  seed : Int32
  checkpoint : String
} derive(FromJson)

///|
priv struct DynamicsReport {
  format : String
  runs : Array[DynamicsRun]
} derive(FromJson)
