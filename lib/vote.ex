defmodule Vote do

  def start(s, term) do
    Monitor.debug(s, 1, "Voting started!")
    # Note that this is a new process, so self() and selfP is different
    for server <- s[:servers], server != s[:selfP], do:
      # We added a vote pid(self) so that people know how to send the message back
      send server, {:requestVote, self(), term, s[:id], Log.getPrevLogIndex(s[:log]), Log.getPrevLogTerm(s[:log])}
    # sets timeout for collecting votes, becomes leader only if received enough votes during this time period
    Process.send_after(self(), {:voteTimeOut}, s.config.election_timeout + DAC.random(s.config.election_timeout))
    collectVotes(s, term)

    if s[:votes] < s[:majority] do
      send s[:selfP], {:newElection, term}
    end
  end

  defp collectVotes(s, term) do
    # Monitor.debug(s, "inside collect vote!")
    receive do
      {:voteTimeOut} ->
        Monitor.debug(s, 1, "collect votes timeout... so sad....")

      {:requestVoteResponse, term, true} ->
        s = State.votes(s, s[:votes] + 1)
        Monitor.debug(s, 1, "collected one vote! The total vote is #{s[:votes]} in #{term}")
        # TODO QUESTION: SPLIT VOTE IF EVEN # OF SERVERS? change majority in DAC?
        if s[:votes] == s[:majority] do
          send s[:selfP], {:elected, term}
          Monitor.debug(s, 1, "enough vote from term #{term}, id: #{s[:id]}")
        else
          collectVotes(s, term)
        end

      {:requestVoteResponse, term, false} ->
        Monitor.debug(s, 1, "didn't get a vote")
        collectVotes(s, term)
    end
  end
end
