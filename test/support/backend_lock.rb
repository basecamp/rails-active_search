# Every adapter but sqlite talks to one server shared by the whole machine, and the suite writes
# fixed database, index and core names into it, so two checkouts running at once overwrite each
# other's documents. sqlite keeps its database in the worktree's own storage/ and needs no lock.
module BackendLock
  class << self
    def acquire(adapter)
      return if adapter == "sqlite"

      # Held on the module for the life of the process: closing the file releases the lock, and a
      # local would let GC do exactly that partway through the run.
      @lock = File.open(path_for(adapter), File::RDWR | File::CREAT, 0o600)

      unless @lock.flock(File::LOCK_EX | File::LOCK_NB)
        warn "Waiting for the #{adapter} backend, held by #{@lock.read}"
        @lock.flock(File::LOCK_EX)
      end

      record_holder
    end

    private
      # The lock belongs to the backend rather than the checkout, so every worktree opens one file.
      # Not Dir.tmpdir: it follows TMPDIR, so a process with its own would take a private lock.
      def path_for(adapter)
        File.join("/tmp", "active_search-suite-#{adapter}-#{Process.uid}.lock")
      end

      # Naming the holder turns a run that looks hung into one that says what it is waiting for.
      def record_holder
        @lock.truncate(0)
        @lock.write("pid #{Process.pid} in #{Dir.pwd}")
        @lock.flush
      end
  end
end
