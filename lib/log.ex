defmodule Log do

  def new() do
    []
    # each log entry will be a map of the following form: %{
    #  term: term_no - int
    #  cmd:  specific command - tuple
    #  uid:  uid - tuple
    # }
  end
  # L is for log and same below.
  def deleteLastElement(l) do
    List.delete_at(l, -1)
  end

  def getPrevLogIndex(l) do
    length(l)
    # the log index start from 1,
    # when the log is empty initially, the prev log index is 0.
  end

  # When the log is empty initially we need to return 0.
  def getPrevLogTerm(l) do
    if length(l) >= 1 do
      List.last(l)[:term]
    else
      0
    end
  end

end
