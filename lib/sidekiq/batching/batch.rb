module Sidekiq
  module Batching
    class Batch

      def initialize(worker_class, queue, redis_pool = nil)
        @worker_class = worker_class
        @queue = queue
        @name = "#{worker_class.underscore}:#{queue}"
        @redis = Sidekiq::Batching::Redis.new
      end

      attr_reader :name, :worker_class, :queue

      def add(msg)
        @redis.push_msg(@name, msg.to_json)
      end

      def size
        @redis.batch_size(@name)
      end

      def chunk_size
        worker_class_options['batch_size'] ||
        Sidekiq::Batching::Config.max_batch_size
      end

      def pluck
        if @redis.lock(@name)
          @redis.pluck(@name, chunk_size).map { |value| JSON.parse(value) }
        end
      end

      def flush
        chunk = pluck
        if chunk
          Sidekiq::Client.push(
            'class' => @worker_class,
            'queue' => @queue,
            'args' => [true, chunk]
          )
        end
      end

      def worker_class_constant
        @worker_class.constantize
      end

      def worker_class_options
        worker_class_constant.get_sidekiq_options
      end

      def could_flush?
        could_flush_on_overflow? || could_flush_on_time?
      end

      private
      def could_flush_on_overflow?
        worker_class_options['batch_size'] &&
        size >= worker_class_options['batch_size']
      end

      def could_flush_on_time?
        last_time = @redis.get_last_execution_time(@name)
        last_time = Time.parse(last_time) if last_time

        interval = worker_class_options['batch_flush_interval']

        if interval
          if last_time.blank?
            set_current_time_as_last
            false
          else
            last_time + interval.seconds < Time.now
          end
        end
      end

      def set_current_time_as_last
        @redis.set_last_execution_time(@name, Time.now)
      end

      class << self
        def all
          redis = Sidekiq::Batching::Redis.new

          redis.batches.map do |name|
            new(*extract_worker_klass_and_queue(name))
          end
        end

        def extract_worker_klass_and_queue(name)
          klass, queue = name.split(':')
          [klass.classify, queue]
        end
      end

    end
  end
end