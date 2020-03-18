require 'cadence/client'
require 'cadence/thread_pool'
require 'cadence/activity/task_processor'

module Cadence
  class Activity
    class Poller
      THREAD_POOL_SIZE = 20

      def initialize(domain, task_list, activity_lookup, middleware)
        @domain = domain
        @task_list = task_list
        @activity_lookup = activity_lookup
        @shutting_down = false
        @middleware = middleware
      end

      def start
        @shutting_down = false
        @thread = Thread.new(&method(:poll_loop))
      end

      def stop
        @shutting_down = true
        Thread.new { Cadence.logger.info('Shutting down activity poller') }.join
      end

      def wait
        thread.join
      end

      private

      attr_reader :domain, :task_list, :activity_lookup, :thread

      def client
        @client ||= Cadence::Client.generate
      end

      def shutting_down?
        @shutting_down
      end

      def poll_loop
        loop do
          thread_pool.wait_for_available_threads

          return if shutting_down?

          Cadence.logger.debug("Polling for activity tasks (#{domain} / #{task_list})")

          task = poll_for_task
          next unless task&.activityId

          thread_pool.schedule { process(task) }
        end
      end

      def poll_for_task
        client.poll_for_activity_task(domain: domain, task_list: task_list)
      rescue StandardError => error
        Cadence.logger.error("Unable to poll for an activity task: #{error.inspect}")
        nil
      end

      def processor_stack
        @processor_stack ||= build_processor_stack
      end

      def build_processor_stack
        # Put the task processor on the bottom of the stack
        stack = ->(task) { TaskProcessor.new(task, activity_lookup).process }
        @middleware.each do |m|
          stack = m.New(stack)
        end
        stack
      end

      def process(task)
        @processor_stack.call(task)
      end

      def thread_pool
        @thread_pool ||= ThreadPool.new(THREAD_POOL_SIZE)
      end
    end
  end
end
