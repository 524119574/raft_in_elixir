defmodule Candidate do
  def start(s) do
    s = State.role(s, :CANDIDATE)
    s = State.curr_term(s, s[:curr_term] + 1)
    spawn(Vote, :start, [s])
    # send self(), {:timeout}
    next(s)
  end

  defp next(s) do
    receive do
      {:Elected, termId} ->
        if (termId == s[:curr_term]) do
          IO.puts "I am the leader!"
          Leader.start(s)
        else
          next(s)
        end
      {:NewElection, termId} ->
        if (termId == s[:curr_term]) do
          Candidate.start(s)
        else
          next(s)
        end
      {:appendEntry, term, leaderId, prevLogIndex} ->
        send Enum.at(s[:servers], leaderId), {:appendEntryResponse, s[:curr_term], true}
        Follower.start(s)
    end
  end

end
