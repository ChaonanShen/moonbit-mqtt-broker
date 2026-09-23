///|
async fn with_capability_dir(
  name : String,
  body : async (String) -> Unit,
) -> Unit {
  let path = "_build/persistence-fs-capability-" + name
  if @fs.exists(path) {
    @fs.rmdir(path, recursive=true)
  }
  @fs.mkdir(path, permission=0o700, recursive=true)
  body(path)
  @fs.rmdir(path, recursive=true)
}

///|
async test "persistence filesystem supports full file and directory sync" {
  with_capability_dir("sync", path => {
    let file_path = path + "/value"
    let file = @fs.open(
      file_path,
      mode=WriteOnly,
      create_mode=CreateNew,
      permission=0o600,
    )
    file.write(b"durable")
    file.sync(only_data=false)
    file.close()
    let directory = @fs.open(path, mode=ReadOnly, create_mode=OpenExisting)
    assert_eq(directory.kind(), Directory)
    directory.sync(only_data=false)
    directory.close()
    assert_eq(@fs.read_file(file_path).text(), "durable")
  })
}

///|
async test "persistence filesystem supports atomic replace rename" {
  with_capability_dir("rename", path => {
    let main = path + "/broker.snapshot"
    let temp = path + "/broker.snapshot.tmp"
    @fs.write_file(main, b"old", create_mode=CreateNew, permission=0o600)
    let file = @fs.open(
      temp,
      mode=WriteOnly,
      create_mode=CreateNew,
      permission=0o600,
    )
    file.write(b"new")
    file.sync(only_data=false)
    file.close()
    @fs.rename(temp, main, replace=true)
    let directory = @fs.open(path, mode=ReadOnly, create_mode=OpenExisting)
    directory.sync(only_data=false)
    directory.close()
    assert_eq(@fs.read_file(main).text(), "new")
    assert_false(@fs.exists(temp))
  })
}

///|
async test "persistence filesystem exclusive locks conflict and release" {
  with_capability_dir("lock", path => {
    let lock_path = path + "/broker.snapshot.lock"
    let first = @fs.open(
      lock_path,
      mode=ReadWrite,
      create_mode=OpenOrCreate,
      permission=0o600,
    )
    let second = @fs.open(lock_path, mode=ReadWrite, create_mode=OpenExisting)
    assert_true(first.try_lock(Exclusive))
    assert_false(second.try_lock(Exclusive))
    first.unlock()
    first.close()
    assert_true(second.try_lock(Exclusive))
    second.unlock()
    second.close()
  })
}

///|
async test "persistence filesystem distinguishes symlinks from regular files" {
  with_capability_dir("kind", path => {
    let regular = path + "/regular"
    let link = path + "/link"
    @fs.write_file(regular, b"data", create_mode=CreateNew, permission=0o600)
    @fs.symlink(target="regular", link)
    assert_eq(@fs.kind(regular, follow_symlink=false), Regular)
    assert_eq(@fs.kind(link, follow_symlink=false), SymLink)
    assert_eq(@fs.kind(link, follow_symlink=true), Regular)
  })
}

///|
async test "persistence task group runs cancelled task cleanup before drain defer" {
  let log : Array[String] = []
  @async.with_task_group() <| group => {
    group.add_defer(() => log.push("drain"))
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      defer log.push("producer-stopped")
      for ;; {
        @async.sleep(1000)
      }
    }
  }
  assert_eq(log, ["producer-stopped", "drain"])
}

///|
async test "persistence recovery truncates only the observed regular WAL tail" {
  with_capability_dir("wal-tail", path => {
    let wal = path + "/wal-1.log"
    @fs.write_file(
      wal,
      b"committed-tail",
      create_mode=CreateNew,
      permission=0o600,
    )
    assert_true(truncate_regular_tail(wal, 14L, 9L) is Ok(_))
    assert_eq(@fs.read_file(wal).text(), "committed")
    assert_true(truncate_regular_tail(wal, 14L, 4L) is Err(_))
    assert_eq(@fs.read_file(wal).text(), "committed")
    let link = path + "/wal-link.log"
    @fs.symlink(target="wal-1.log", link)
    assert_true(truncate_regular_tail(link, 9L, 4L) is Err(_))
    assert_eq(@fs.read_file(wal).text(), "committed")
  })
}

///|
async test "persistence filesystem supports append and offset writes" {
  with_capability_dir("append-offset", path => {
    let file_path = path + "/wal"
    let file = @fs.open(
      file_path,
      mode=ReadWrite,
      create_mode=CreateNew,
      permission=0o600,
    )
    file.write_at(b"abc", position=0L)
    file.write_at(b"def", position=3L)
    file.sync(only_data=false)
    assert_eq(file.size(), 6L)
    file.close()
    let append = @fs.open(
      file_path,
      mode=WriteOnly,
      create_mode=OpenExisting,
      append=true,
    )
    append.write(b"ghi")
    append.sync(only_data=false)
    append.close()
    assert_eq(@fs.read_file(file_path).text(), "abcdefghi")
    let truncate = @fs.open(
      file_path,
      mode=WriteOnly,
      create_mode=TruncateExisting,
    )
    truncate.sync(only_data=false)
    truncate.close()
    assert_eq(@fs.read_file(file_path).text(), "")
  })
}
