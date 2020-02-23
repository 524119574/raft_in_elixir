defmodule Follower do
  def start(s) do
    Monitor.debug(s, 4, "becomes follower with log length #{Log.getLogSize(s[:log])}")
    s = State.role(s, :FOLLOWER)
    s = State.voted_for(s, nil)
    s = State.votes(s, 0)
    timer = Process.send_after(self(), {:timeout}, s.config.election_timeout + DAC.random(s.config.election_timeout))
    next(s, timer)
  end

  defp next(s, timer) do

    receive do

      {:crash_timeout} ->

        Monitor.debug(s, 4, "follower crashed and will NOT restart with log length #{Log.getLogSize(s[:log])}")
        Process.sleep(30_000)

      {:crash_and_restart} ->

        Process.cancel_timer(timer)
        Monitor.debug(s, 4, "follower crashed and will sleep for 1000 ms")
        Process.sleep(1000)
        Monitor.debug(s, 4, "follower finished sleeping and restarted")
        next(s, resetTimer(timer, s.config.election_timeout))

      {:appendEntry, term, leaderId,
       prevLogIndex, prevLogTerm,
       entries, leaderCommit} ->

        # Update current term and voted for if the term received is larger than self.
        s = cond do
              term > s[:curr_term] -> State.curr_term(State.voted_for(s, nil), term)
              true -> s
            end

        # save the leader id in current term
        s = cond do
              leaderId != s[:leaderId] or s[:leaderId] == nil -> State.leader_id(s, leaderId)
              true -> s
            end

        s = cond do
              leaderCommit > s[:last_applied] ->

                s = State.commit_index(s, leaderCommit)
                commitEntries(s)

              true -> s
            end

        cond do
          term < s[:curr_term] ->

            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], false, self(), nil})
            next(s, resetTimer(timer, s.config.election_timeout))

          entries == nil -> # heartbeat

            next(s, resetTimer(timer, s.config.election_timeout))

          !isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) ->
            # Monitor.debug(s, 2, "follower rcved entry #{inspect(entries)} with prevLogIndex #{prevLogIndex} term #{prevLogTerm}")
            # Monitor.debug(s, 2, "before deleting log length is #{Log.getLogSize(s[:log])})"

            # The max also handle the case where the log is shorter.
            s = State.log(s, Log.deleteNEntryFromLast(s[:log], max(Log.getLogSize(s[:log]) - prevLogIndex + 1, 0)))
            # Monitor.debug(s, 2, "after deleting log length is #{Log.getLogSize(s[:log])})"
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], false, nil})
            next(s, resetTimer(timer, s.config.election_timeout))

          true ->
            # Remove all entries after the prevIndex but not including the prevIndex
            s = State.log(s, Log.deleteNEntryFromLast(s[:log], Log.getLogSize(s[:log]) - prevLogIndex))
            s = State.log(
              s, Enum.reduce(entries, s[:log],
                             fn entry, log -> Log.appendNewEntry(log, entry, prevLogIndex + 1, entry[:term]) end))
            # Monitor.debug(s, 2, "Log updated log length #{length(s[:log])} cur term: #{s[:curr_term]}")

            s = State.commit_index(s, if leaderCommit > s[:commit_index]
                                      do min(leaderCommit, Log.getLogSize(s[:log]))
                                      else s[:commit_index] end)

            s = commitEntries(s)
            send(Enum.at(s[:servers], leaderId - 1),
                 {:appendEntryResponse, s[:curr_term], true, self(), Log.getPrevLogIndex(s[:log])})
            Monitor.debug(s, "Updated log length #{Log.getLogSize(s[:log])}," <>
              "last applied: #{s[:last_applied]} #{inspect(s[:log][s[:last_applied]])} commit index: #{leaderCommit}")
            next(s, resetTimer(timer, s.config.election_timeout))

        end

      {:requestVote, votePid, term, candidateId, lastLogIndex, lastLogTerm} ->
        s =
        cond do
          # Update current term if the term received is larger than self.
          term > s[:curr_term] -> State.curr_term(State.voted_for(s, nil), term)
          true -> s
        end
        up_to_date = lastLogTerm > Log.getPrevLogTerm(s[:log]) or
                    (lastLogTerm == Log.getPrevLogTerm(s[:log]) and lastLogIndex >= Log.getPrevLogIndex(s[:log]))
        cond do
          term > s[:curr_term] and up_to_date ->
            s = State.voted_for(s, candidateId)
            # Monitor.debug(s, 1, "term bigger: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            next(s, resetTimer(timer, s.config.election_timeout))
          term == s[:curr_term] and up_to_date and (s[:voted_for] == nil or s[:voted_for] == candidateId) ->
            s = State.voted_for(s, candidateId)
            # Monitor.debug(s, 1, "term equal: received request vote and voted for #{candidateId} in term #{term}!")
            send votePid, {:requestVoteResponse, s[:curr_term], true}
            next(s, resetTimer(timer, s.config.election_timeout))
          true ->
            send votePid, {:requestVoteResponse, s[:curr_term], false}
            next(s, resetTimer(timer, s.config.election_timeout))
        end

      {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}} ->

        if s[:leaderId] != nil do
          Monitor.debug(s, 2, "follower forwarded client request to leader #{s[:leaderId]}")
          send(Enum.at(s[:servers], s[:leaderId] - 1), {:CLIENT_REQUEST, %{clientP: client, uid: uid, cmd: cmd}})
        end

        Monitor.debug(s, 2, "follower received client request but do not know leader")
        next(s, resetTimer(timer, s.config.election_timeout))

      {:timeout} ->

        Monitor.debug(s, 4, "converts to candidate from follower in term #{s[:curr_term]} (+1)")
        Process.cancel_timer(timer)
        Candidate.start(s)

    end
  end

  defp resetTimer(timer, timeout) do
    Process.cancel_timer(timer)
    Process.send_after(self(), {:timeout}, timeout + DAC.random(timeout))
  end

  defp isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) do
    # Monitor.debug(s, 2, "prev entry look at #{inspect(Enum.at(s[:log], prevLogIndex - 1))}")
    (prevLogIndex == 0 or s[:log][prevLogIndex][:term] == prevLogTerm)
  end

  defp commitEntries(s) do
    if s[:commit_index] > s[:last_applied] do
      num_to_execute = s[:commit_index] - s[:last_applied]
      Monitor.debug(s, "committing some log: #{inspect(Log.getEntriesBetween(s[:log], s[:last_applied] + 1, s[:commit_index]))}")
      for i <- 1..num_to_execute do
        send s[:databaseP], {:EXECUTE, s[:log][s[:last_applied] + i][:cmd]}
      end
      s = State.last_applied(s, s[:commit_index])
      Monitor.debug(s, "committed some log: " <>
      "log length #{Log.getLogSize(s[:log])}, " <>
      "last applied == commitIndex: #{s[:last_applied]}")
      s
    else
      s
    end
  end


end
