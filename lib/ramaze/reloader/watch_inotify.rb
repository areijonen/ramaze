module Ramaze
  class Reloader
    # TODO:
    #   * There seems to be a problem somewhere that I couldn't identify yet, a
    #     file has to be modified twice initially to make it show up as
    #     modified here, subsequent changes work just fine.
    #     The only workaround I could find right now would be to read/write
    #     every single file, but that would be unexpected, irresponsible, and
    #     error-prone.
    #
    # NOTE:
    #   * I have changed from using a Mutex to using a Queue, which uses a
    #     Mutex internally.

    class WatchInotify
      POLL_INTERVAL = 2 # seconds
      NOTIFY_MASK = RInotify::CREATE | RInotify::MOVED_TO | RInotify::CLOSE_WRITE | RInotify::MODIFY

      def initialize
        @watched_files = Set.new
        @watcher = RInotify.new
        @changed = Queue.new
        @watcher_thread = start_watcher
      end

      def call(cooldown)
        yield
      end

      # TODO: define a finalizer to cleanup? -- reloader never calls #close

      def start_watcher
        Thread.new{ loop{ watcher_cycle }}
      end

      # Not much work here, we just have to empty the event queue and push the
      # descriptors for reloading on next request.
      def watcher_cycle
        return unless @watcher.wait_for_events(POLL_INTERVAL)

        @watcher.each_event do |event|
          # [directory_descriptor, filename] 
          @changed.push([event.watch_descriptor, event.name])
        end
      end

      def watch(file)
        return if @watched_files.include?(file)
        return if not File.exist?(file)
        @watched_files << file
        dirname = File.dirname(file)
        return if @watcher.watch_descriptors.has_value?(dirname)
        @watcher.add_watch(dirname, NOTIFY_MASK)
      rescue Errno::ENOENT
        retry
      end

      def remove_watch(file)
        return unless @watched_files.include?(file)
        @watched_files.delete(file)
        directory = File.dirname(file)

        # remove directory watch if last watched file in directory
        if not @watched_files.find {|f| File.dirname(f) == directory }
          descriptor,* = @watcher.watch_descriptors.find {|k,v| v == directory }
          @watcher.rm_watch(descriptor) if descriptor
        end
      end

      def close
        @watcher_thread.terminate
        @watcher.close
        true
      end

      def changed_files
        files = Set.new
        until @changed.empty?
          directory_descriptor, file = @changed.shift
          directory = @watcher.watch_descriptors[directory_descriptor]
          path = "#{directory}/#{file}"
          # can't yield yet, could have duplicates
          files << path if @watched_files.include? path
        end
        files.each {|f| yield f }
      end
    end
  end
end
