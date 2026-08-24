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
