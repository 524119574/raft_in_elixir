defmodule Candidate do
  def start(s) do
    s = State.role(s, :CANDIDATE)
    s = State.curr_term(s, s[:curr_term] + 1)
    s = State.voted_for(s, self())
    spawn(Vote, :start, [s])
    next(s)
  end

  defp next(s) do
    receive do

      { :crash_timeout } -> Monitor.debug(s, "crashed")
      
      {:Elected, termId} ->
        # We add the if check here because we want to avoid the situation
        # where the candidate spin up the vote process and then becomes the
        # follower because it receive appendEntry from another leader and then
        # it times out and becomes the candidate again. And only at this time
        # the candidate receive the message from vote module.

        # Well it seems like this situation can never happen? Since each term
        # there can only be one leader, no?
        if (termId == s[:curr_term]) do
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

      {:appendEntry, term, leaderId, prevLogIndex, prevLogTerm, entries, leaderCommit} ->
        Monitor.debug(s, "converts to follower from candidate in term #{s[:curr_term]}")
        if term >= s[:curr_term] do
          s = State.curr_term(s, term)
          # TODO: append entry response format not sure if correct
          send Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true}
          Follower.start(s)
        end
    end
  end #defp

end #Candidate
