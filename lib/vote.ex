defmodule Vote do

  def start(s, term) do
    # Monitor.debug(s, "Voting started!")
    # s = State.voted_for(s, self())
    # s = State.votes(s, s[:votes] + 1)

    # Note that this is a new process, so self() and selfP is different
    for server <- s[:servers], server != s[:selfP], do:
      # We added a vote pid(self) so that people know how to send the message back,
      # this is an additional attributes on top of the normal RAFT attributes.
      send server, {:requestVote, self(), term, s[:id], Log.getPrevLogIndex(s[:log]), Log.getPrevLogTerm(s[:log])}

    #TODO: change the time
    Process.send_after(self(), {:voteTimeOut}, (100 + DAC.random(100)))

    collectVotes(s, term)

    if s[:votes] < s[:majority] do
      send s[:selfP], {:NewElection, term}
    end
  end

  defp collectVotes(s, term) do
    # Monitor.debug(s, "inside collect vote!")
    receive do
      {:voteTimeOut} ->
        Monitor.debug(s, "timeout... so sad....")

      {:requestVoteResponse, term, true} ->
        s = State.votes(s, s[:votes] + 1)
        Monitor.debug(s, "collected one vote! The total vote is #{s[:votes]} in #{term}")
        # QUESTION: SPLIT VOTE IF EVEN # OF SERVERS?
        if s[:votes] == s[:majority] do
          send s[:selfP], {:Elected, term}
          Monitor.debug(s, "enough vote from term #{term}, id: #{s[:id]}")
        else
          collectVotes(s, term)
        end

      {:requestVoteResponse, term, false} ->
        Monitor.debug(s, "didn't get a vote")
        collectVotes(s, term)
    end

  end

end
