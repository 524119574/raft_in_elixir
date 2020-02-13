defmodule Follower do
  def start(s) do
    s = State.role(s, :FOLLOWER)
    # TODO: random 100!
    timer = Process.send_after(self(), {:timeout}, 100 + DAC.random(500))
    next(s, timer)
  end

  defp next(s, timer) do
    receive do
      {:appendEntry, term, leaderId,
       prevLogIndex, prevLogTerm,
       entries, leaderCommit} = m ->
        if term > s[:curr_term] do
          s = State.voted_for(s, nil)
          s = State.curr_term(s, term)
        end
        cond do
          term < s[:curr_term] ->
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], false})
            next(s, resetTimer(timer))
          !isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) ->
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], false})
            next(s, resetTimer(timer))
          entries != nil ->
            s = State.log(s, Enum.concat(s[:log], (for entry <- entries, do: %{term: term, uid: 0, cmd: entry})))
            if leaderCommit > s[:commit_index] do
              s = State.commit_index(s, min(leaderCommit, length(s[:log])))
            end
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true, m})
            Monitor.debug(s, "Log updated log length #{length(s[:log])}")
            next(s, resetTimer(timer))
          true -> # heartbeat
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true})
            next(s, resetTimer(timer))
        end

      # TODO: voting logic add up-do-date check in sec 5.4
      {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} ->
        cond do
          term < s[:curr_term] ->
            send votePid, {:requestVoteResponse, s[:curr_term], false}
            next(s, resetTimer(timer))
          term > s[:curr_term] ->
            s = State.curr_term(s, term)
            s = State.voted_for(s, candidateId)
            Monitor.debug(s, "term bigger: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            # TODO: do we need to reset the timer here?
            next(s, resetTimer(timer))
          term == s[:curr_term] and (s[:voted_for] == nil or s[:voted_for] == candidateId) ->
            s = State.voted_for(s, candidateId)
            Monitor.debug(s, "term equal: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            # TODO: do we need to reset the timer here?
            next(s, resetTimer(timer))
          true ->
            Monitor.debug(s, "In term #{term}, no vote!")
        end

      {:timeout} -> Candidate.start(s)
    end
  end

  defp resetTimer(timer) do
    Process.cancel_timer(timer)
    Process.send_after(self(), {:timeout}, (100 + DAC.random(500)))
  end

  defp isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) do
    (length(s[:log]) >= prevLogIndex and
     (prevLogIndex == 0 or
      Enum.at(s[:log], prevLogIndex - 1)[:term] == prevLogTerm))
  end

end
