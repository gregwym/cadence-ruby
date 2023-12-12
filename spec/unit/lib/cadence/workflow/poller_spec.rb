require 'cadence/workflow/poller'
require 'cadence/middleware/entry'
require 'cadence/configuration'

describe Cadence::Workflow::Poller do
  let(:connection) { instance_double('Cadence::Connection::Thrift') }
  let(:domain) { 'test-domain' }
  let(:task_list) { 'test-task-list' }
  let(:lookup) { instance_double('Cadence::ExecutableLookup') }
  let(:thread_pool) do
    instance_double(Cadence::ThreadPool, wait_for_available_threads: nil, shutdown: nil)
  end
  let(:config) { Cadence::Configuration.new }
  let(:middleware_chain) { instance_double(Cadence::Middleware::Chain) }
  let(:middleware) { [] }
  let(:workflow_middleware_chain) { instance_double(Cadence::Middleware::Chain) }
  let(:empty_middleware_chain) { instance_double(Cadence::Middleware::Chain) }
  let(:workflow_middleware) { [] }

  subject { described_class.new(domain, task_list, lookup, config, middleware, workflow_middleware) }

  before do
    allow(Cadence::Connection).to receive(:generate).and_return(connection)
    allow(Cadence::ThreadPool).to receive(:new).and_return(thread_pool)
    allow(Cadence::Middleware::Chain).to receive(:new).with(workflow_middleware).and_return(workflow_middleware_chain)
    allow(Cadence::Middleware::Chain).to receive(:new).with(middleware).and_return(middleware_chain)
    allow(Cadence::Middleware::Chain).to receive(:new).with([]).and_return(empty_middleware_chain)
    allow(connection).to receive(:poll_for_decision_task).and_return(nil)
    allow(Cadence.metrics).to receive(:timing)
  end

  describe '#start' do
    it 'polls for decision tasks' do
      allow(subject).to receive(:shutting_down?).and_return(false, false, true)

      subject.start

      # stop poller before inspecting
      subject.stop; subject.wait

      expect(connection)
        .to have_received(:poll_for_decision_task)
        .with(domain: domain, task_list: task_list)
        .twice
    end

    it 'polls for decision tasks' do
      allow(subject).to receive(:shutting_down?).and_return(false, false, true)

      subject.start

      # stop poller before inspecting
      subject.stop; subject.wait

      expect(Cadence.metrics)
        .to have_received(:timing)
        .with(
          'workflow_poller.time_since_last_poll',
          an_instance_of(Integer),
          domain: domain,
          task_list: task_list
        )
        .twice
    end

    context 'with options passed' do
      subject { described_class.new(domain, task_list, lookup, config, middleware, workflow_middleware, options) }
      let(:options) { { polling_ttl: 42, thread_pool_size: 42 } }

      before do
        allow(subject).to receive(:shutting_down?).and_return(false, true)
      end

      it 'passes options to the connection' do
        subject.start

        # stop poller before inspecting
        subject.stop; subject.wait

        expect(Cadence::Connection)
          .to have_received(:generate)
          .with(config.for_connection, options)
      end

      it 'creates thread pool of a specified size' do
        subject.start

        # stop poller before inspecting
        subject.stop; subject.wait

        expect(Cadence::ThreadPool).to have_received(:new).with(42)
      end
    end

    context 'when an decision task is received' do
      let(:task_processor) do
        instance_double(Cadence::Workflow::DecisionTaskProcessor, process: nil)
      end
      let(:task) { Fabricate(:decision_task_thrift) }

      before do
        allow(subject).to receive(:shutting_down?).and_return(false, true)
        allow(connection).to receive(:poll_for_decision_task).and_return(task)
        allow(Cadence::Workflow::DecisionTaskProcessor).to receive(:new).and_return(task_processor)
        allow(thread_pool).to receive(:schedule).and_yield
      end

      it 'schedules task processing using a ThreadPool' do
        subject.start

        # stop poller before inspecting
        subject.stop; subject.wait

        expect(thread_pool).to have_received(:schedule)
      end

      it 'uses DecisionTaskProcessor to process tasks' do
        subject.start

        # stop poller before inspecting
        subject.stop; subject.wait

        expect(Cadence::Workflow::DecisionTaskProcessor)
          .to have_received(:new)
          .with(task, domain, lookup, empty_middleware_chain, empty_middleware_chain, config)
        expect(task_processor).to have_received(:process)
      end

      context 'with middleware configured' do
        class TestPollerMiddleware
          def initialize(_); end
          def call(_); end
        end

        let(:workflow_middleware) { [entry_1] }
        let(:middleware) { [entry_1, entry_2] }
        let(:entry_1) { Cadence::Middleware::Entry.new(TestPollerMiddleware, '1') }
        let(:entry_2) { Cadence::Middleware::Entry.new(TestPollerMiddleware, '2') }

        it 'initializes middleware chain and passes it down to DecisionTaskProcessor' do
          subject.start

          # stop poller before inspecting
          subject.stop; subject.wait

          expect(Cadence::Middleware::Chain).to have_received(:new).with(middleware)
          expect(Cadence::Middleware::Chain).to have_received(:new).with(workflow_middleware)
          expect(Cadence::Workflow::DecisionTaskProcessor)
            .to have_received(:new)
            .with(task, domain, lookup, middleware_chain, workflow_middleware_chain, config)
        end
      end
    end

    context 'when connection is unable to poll' do
      before do
        allow(subject).to receive(:shutting_down?).and_return(false, true)
        allow(connection).to receive(:poll_for_decision_task).and_raise(StandardError)
      end

      it 'logs' do
        allow(Cadence.logger).to receive(:error)

        subject.start

        # stop poller before inspecting
        subject.stop; subject.wait

        expect(Cadence.logger)
          .to have_received(:error)
          .with('Unable to poll for a decision task: #<StandardError: StandardError>')
      end
    end
  end

  describe '#wait' do
    before do
      subject.start
      subject.stop
    end

    it 'shuts down the thread poll' do
      subject.wait

      expect(thread_pool).to have_received(:shutdown)
    end
  end
end
