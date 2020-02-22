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
      { :crash_timeout } ->
        # Monitor.debug(s, 4, "crashed and will sleep for 1000 ms")
        # Process.sleep(1000)
        # Monitor.debug(s, 4, "follower finished sleeping and restarted")
        # next(s, resetTimer(timer, s.config.election_timeout))
        Monitor.debug(s, 4, "follower crashed and will NOT restart with log length #{Log.getLogSize(s[:log])}")
        Process.sleep(30_000)

      {:appendEntry, term, leaderId,
       prevLogIndex, prevLogTerm,
       entries, leaderCommit} = m ->
        # leader who sent the message is out-of-date
        if term < s[:curr_term] do
          send(Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()})
          next(s, resetTimer(timer, s.config.election_timeout))
        end
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

        cond do
          # heartbeat
          entries == nil ->
            next(s, resetTimer(timer, s.config.election_timeout))
     
          # log shorter, does not contain an entry at prevLogIndex
          Log.getLogSize(s[:log]) < prevLogIndex ->
            # Monitor.debug(s, 2, "log shorter!")
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()})
            next(s, resetTimer(timer, s.config.election_timeout))

          !isPreviousEntryMatch(s, prevLogIndex, prevLogTerm) ->
            # Monitor.debug(s, 2, "previous entry not matching will delete entries")
            # Monitor.debug(s, 2, "follower rcved entry #{inspect(Enum.at(entries, 0))} with prevLogIndex #{prevLogIndex} term #{prevLogTerm}")
            # Monitor.debug(s, 2, "before deleting log length is #{Log.getLogSize(s[:log])})"
            s = State.log(s, Log.deleteNEntryFromLast(s[:log], Log.getLogSize(s[:log]) - prevLogIndex + 1))
            # Monitor.debug(s, 2, "after deleting log length is #{Log.getLogSize(s[:log])})"
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryFailedResponse, s[:curr_term], false, self()})
            next(s, resetTimer(timer, s.config.election_timeout))

          true ->
            # update log
            s = State.commit_log(s, Enum.at(entries, 0)[:uid], false)
            s = State.log(
              s, Enum.reduce(entries, s[:log],
                             fn entry, log -> Log.appendNewEntry(log, entry, prevLogIndex + 1, entry[:term]) end))
            send(Enum.at(s[:servers], leaderId - 1), {:appendEntryResponse, s[:curr_term], true, m, self(), prevLogIndex + 1})
            # Monitor.debug(s, 2, "Log updated log length #{length(s[:log])} cur term: #{s[:curr_term]}")

            # update commit index if necessary
            s = State.commit_index(s, if leaderCommit > s[:commit_index]
                                      do min(leaderCommit, Log.getLogSize(s[:log]))
                                      else s[:commit_index] end)
            # Monitor.debug(s, 2, "follower commit index is #{s[:commit_index]} rcved from leader is #{leaderCommit}")

            # execute cmds and update last_applied if necessary
            if s[:commit_index] > s[:last_applied] do
              # Monitor.debug(s, 2, "cmt - apply is #{s[:commit_index] - s[:last_applied]}")
              num_to_execute = s[:commit_index] - s[:last_applied]
              for i <- 1..num_to_execute do
                send s[:databaseP], {:EXECUTE, s[:log][s[:last_applied] + i][:cmd]}
              end
              # s = Enum.reduce(1..num_to_execute, s, fn i, s -> State.commit_log(s, s[:log][s[:last_applied] + i][:uid], true) end)
              s = State.last_applied(s, s[:commit_index])
              # Monitor.debug(s, 2, "follower last applied is #{s[:last_applied]}")
              next(s, resetTimer(timer, s.config.election_timeout))
            end
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
          next(s, resetTimer(timer, s.config.election_timeout))
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

end
