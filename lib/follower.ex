defmodule Follower do
  def start(s) do
    s = State.role(s, :FOLLOWER)
    s = State.voted_for(s, nil)
    s = State.votes(s, 0)
    # TODO: random 100!
    timer = Process.send_after(self(), {:timeout}, 100 + DAC.random(500))
    next(s, timer)
  end

  defp next(s, timer) do
    receive do
      # currently don't restart after crash, can change to sleep
      { :crash_timeout } -> Monitor.debug(s, "crashed")

      {:appendEntry, term, leaderId,
       prevLogIndex, prevLogTerm,
       entries, leaderCommit} = m ->
        if term > s[:curr_term] do
          s = State.voted_for(s, nil)
          s = State.curr_term(s, term)
        end
        cond do
          term < s[:curr_term] ->
            # TODO: this means leader is out-of-date right? should we send a different response to differentiate from second case
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], false})
            next(s, resetTimer(timer))
          !isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) ->
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], false, self()})
            next(s, resetTimer(timer))
          entries != nil ->
            s = State.log(s, Enum.concat(s[:log], (for entry <- entries, do: entry)))
            if leaderCommit > s[:commit_index] do
              s = State.commit_index(s, min(leaderCommit, length(s[:log])))
            end
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true, m})
            Monitor.debug(s, "Log updated log length #{length(s[:log])}")
            next(s, resetTimer(timer))
          # Question: how to differentiate hearbeat response from append entry response?
          true -> # heartbeat
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true})
            next(s, resetTimer(timer))
        end

      # TODO: voting logic not sure if entirely correct
      {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} ->
        up_to_date = lastLogTerm > Log.getPrevLogTerm(s[:log]) or 
                    (lastLogTerm == Log.getPrevLogTerm(s[:log]) and lastLogIndex >= Log.getPrevLogIndex(s[:log]))
        cond do
          term < s[:curr_term] or !up_to_date ->
            send votePid, {:requestVoteResponse, s[:curr_term], false}
            next(s, resetTimer(timer))
          term > s[:curr_term] and up_to_date ->
            s = State.curr_term(s, term)
            s = State.voted_for(s, candidateId)
            Monitor.debug(s, "term bigger: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            # TODO: do we need to reset the timer here?
            next(s, resetTimer(timer))
          term == s[:curr_term] and (s[:voted_for] == nil or s[:voted_for] == candidateId) and up_to_date ->
            s = State.voted_for(s, candidateId)
            Monitor.debug(s, "term equal: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            # TODO: do we need to reset the timer here?
            next(s, resetTimer(timer))
          true ->
            Monitor.debug(s, "In term #{term}, no vote!")
        end

      # TODO: forward client request to current leader
      # {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}} ->
      #   # how do follower know the address of leader?
      #   next(s, timer)

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
