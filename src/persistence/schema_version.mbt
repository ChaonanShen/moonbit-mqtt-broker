///|
pub let mqtt5_snapshot_model_version : Int = 5

///|
pub let mqtt5_snapshot_envelope_version : Int = 5

///|
pub let mqtt5_wal_logical_schema : Int = 6

///|
pub let mqtt5_business_delta_version : Int = 2

///|
pub let mqtt5_checkpoint_version : Int = 3

///|
pub let mqtt5_manifest_version : Int = 3

///|
pub let mqtt5_reconcile_version : Int = 2

///|
pub let feature_policy_gate : UInt = 1U

///|
pub let feature_shared_records : UInt = 2U

///|
pub let feature_mqtt5_model : UInt = 4U

///|
pub fn supported_mqtt5_features(value : UInt) -> Bool {
  value <= 7U
}
