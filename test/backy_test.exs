defmodule BackyTest do
  use ExUnit.Case
  doctest Backy

  defmodule User do
    defstruct [name: nil]
  end

  defmodule TestWorker do
    use Backy.Worker, max_concurrency: 10

    def perform(%Backy.Job{}, [arg1, %{name: name, foo: _}]) do
      send :backy_test, { :job_has_been_run, name_was: name, arg1_was: arg1 }
    end

    def perform(%Backy.Job{}, %{name: name}) do
      send :backy_test, { :job_has_been_run, name_was: name }
    end

    def perform(%Backy.Job{}, %{width: width, height: height}) do
      send :backy_test, { :job_has_been_run, width_was: width, height_was: height }
    end

    def perform(%Backy.Job{}, [arg1, arg2, arg3]) do
      send :backy_test, { :job_has_been_run, arg1_was: arg1,
                                             arg2_was: arg2,
                                             arg3_was: arg3}
    end

  end

  setup do
    Process.register(self(), :backy_test)
    :ok
  end

  test "enqueuing jobs" do
    job = Backy.enqueue(TestWorker, ["Hello", [name: "Jon Doe", foo: "bar"]])
    assert(job.id)
    assert_receive { :job_has_been_run, name_was: "Jon Doe", arg1_was: "Hello" }
    :timer.sleep 100

    job = Backy.enqueue(TestWorker, name: "Single arg")
    assert(job.id)
    assert_receive { :job_has_been_run, name_was: "Single arg" }
    :timer.sleep 100

    job = Backy.enqueue(TestWorker, %User{name: "user name"})
    assert(job.id)
    assert_receive { :job_has_been_run, name_was: "user name" }
    :timer.sleep 100


    job = Backy.enqueue(TestWorker, width: 1024, height: 768)
    assert(job.id)
    assert_receive { :job_has_been_run, width_was: 1024, height_was: 768 }
    :timer.sleep 100

    assert Backy.JobStore.reserve == nil
  end

  test "store and execute jobs" do
    # Only store jobs, and wait for DB import job to execute them
    
    job = store_only(TestWorker, ["Hello", [name: "Jon Doe", foo: "bar"]])
    assert(job.id)
    job = store_only(TestWorker, name: "Single arg")
    assert(job.id)
    job = store_only(TestWorker, %User{name: "user name"})
    assert(job.id)
    job = store_only(TestWorker, width: 1024, height: 768)
    assert(job.id)
    job = store_only(TestWorker, ["foo", :atom_arg, "bar"])
    assert(job.id)

    :timer.sleep 2000

    assert_receive { :job_has_been_run, name_was: "Jon Doe", arg1_was: "Hello" }
    assert_receive { :job_has_been_run, name_was: "Single arg" }
    assert_receive { :job_has_been_run, name_was: "user name" }
    assert_receive { :job_has_been_run, width_was: 1024, height_was: 768 }
    assert_receive { :job_has_been_run, arg1_was: "foo", 
                                        arg2_was: "atom_arg", 
                                        arg3_was: "bar" }

    assert Backy.JobStore.reserve == nil
  end


  defp store_only(worker, arguments) do
    %Backy.Job{worker: worker, arguments: arguments}
    |> Backy.JobStore.persist(false)
  end
end
