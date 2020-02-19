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

  def appendNewEntry(log, entry) do
    log = Map.put(log, Log.getNextAvailableIndex(log), entry)
    Map.put(log, :log_length, log[:log_length] + 1)
  end

  def getLogSize(log) do
    log[:log_length]
  end

  def getNextAvailableIndex(log) do
    log[:log_length] + 1
  end

  # the log index start from 1,
  # when the log is empty initially, the prev log index is 0.
  def getPrevLogIndex(log) do
    log[:log_length]
  end

  # When the log is empty initially we need to return 0.
  def getPrevLogTerm(log) do
    if Log.getLogSize(log) == 0 do
      0
    else
      log[Log.getPrevLogIndex(log)][:term]
    end
  end

  def deleteNEntryFromLast(log, numOfEntriesToDelete) do
    if Log.getLogSize(log) < numOfEntriesToDelete do
      IO.puts "The entries to be delete is #{numOfEntriesToDelete} while the" <>
      "log size is #{Log.getLogSize(log)}"
    end
    prevIndex = Log.getPrevLogIndex(log)
    length = Log.getLogSize(log)
    log = Enum.reduce(0..numOfEntriesToDelete - 1, log, fn diff, log -> Map.delete(log, prevIndex - diff) end)
    Map.put(log, :log_length, length - numOfEntriesToDelete)
  end

end
