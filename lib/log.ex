defmodule Log do

  def new() do
    %{
      log_length: 0
    }
    # each log entry will be a map of the following form: %{
    #  term: term_no - int
    #  cmd:  specific command - tuple
    #  uid:  uid - tuple
    #  clientP: client proces Id
    # }
  end

  def append_new_entry(log, entry) do
    log = Map.put(log, Log.get_next_available_index(log), entry)
    Map.put(log, :log_length, log[:log_length] + 1)
  end

  def append_new_entry(log, entry, index, term) do
    # check if entry in existing log matches, if so no need to change anything
    if index <= Log.get_log_size(log) and log[index][:term] == term do
      log
    else
      append_new_entry(log, entry)
    end
  end

  def get_log_size(log) do
    log[:log_length]
  end

  def get_next_available_index(log) do
    log[:log_length] + 1
  end

  # the log index start from 1,
  # when the log is empty initially, the prev log index is 0.
  def get_prev_log_index(log) do
    log[:log_length]
  end

  # When the log is empty initially we need to return 0.
  def get_prev_log_term(log) do
    if Log.get_log_size(log) == 0 do
      0
    else
      log[Log.get_prev_log_index(log)][:term]
    end
  end

  def delete_n_entries_from_last(log, num_of_entries_to_delete) do
    if Log.get_log_size(log) < num_of_entries_to_delete do
      IO.puts "The entries to be delete is #{num_of_entries_to_delete} while the" <>
      "log size is #{Log.get_log_size(log)}"
    end
    if (num_of_entries_to_delete == 0) do
      log
    else
      prev_index = Log.get_prev_log_index(log)
      length = Log.get_log_size(log)
      log = Enum.reduce(0..num_of_entries_to_delete - 1, log,
                        fn diff, log -> Map.delete(log, prev_index - diff) end)
      Map.put(log, :log_length, length - num_of_entries_to_delete)
    end
  end



  def get_entries_between(log, start_index, end_index) do
    for i <- start_index..end_index do
      log[i]
    end
  end

  def get_entries_starting_from(log, start_index) do
    Log.get_entries_between(log, start_index, Log.get_prev_log_index(log))
  end
end
