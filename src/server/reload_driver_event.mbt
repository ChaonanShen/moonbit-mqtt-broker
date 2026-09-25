///|
pub(all) enum ReloadDriverReply {
  ReloadDriverReady
  ReloadDriverWaiting
  ReloadDriverStaged
  ReloadDriverActivated(Int64, Int64)
  ReloadDriverRejected(String)
} derive(Eq, Debug)

///|
pub(all) enum ReloadDriverCommand {
  ReloadEnterBarrier(@async.Queue[ReloadDriverReply])
  ReloadActivate(PreparedReload, Int64, @async.Queue[ReloadDriverReply])
  ReloadCommitPolicy(PreparedReload, Int64, @async.Queue[ReloadDriverReply])
  ReloadQueryCompletion(Int64, @async.Queue[ReloadDriverReply])
}
