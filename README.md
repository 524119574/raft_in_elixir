# An implementation of RAFT algorithm in Elixir

### Author Names: Ivory Zhu (yz1020), Wang Ge (wg116)

## To simulate server crash / crash and restart:
- Set the times in the crash_server map in dac.ex line 60 to be 
 `{key: server_id, value: the global time that you want the server to crash}`
- Set the message in `server.ex` line 12 to be `{:crash}` or `{:crash_and_restart}`.
- If the message is `{:crash_and_restart}`, by default the server will sleep for 1000ms.
- To change the sleep time, change `follower.ex` line 25 and `leader.ex` line 39. 

## To simulate leader crash / crash and restart:
- In `leader.ex` line 23, set the second argument to be `{:crash}` or `{:crash_and_restart}`, and the third argument to be the time you want the leader to crash after it gets elected.

## To simulate different election timeouts:
- Set the election_timeout parameter in dac.ex line 57 to desired election timeout.

## A list of existing output logs:

- `5_servers_leader_crash_twice.txt` -> leader sends crash\_timeout every 4000ms in `leader.ex`: note that the sum of requests match

- `5_servers_leader_crash_and_restart_twice.txt` -> leader sends `crash_timeout` every 4000ms in `leader.ex` -> leader sends `crash_and_restart` every 4000ms in leader.ex:  note the small max lag, which means leader log is successfully enforced onto followers after it restarted

- `5_servers_follower_crash_every_2s.txt` -> set `crash\_timeout` to 1000ms, 3000ms, 5000ms in `dac.ex`

- `5_servers_follower_crash_and_restart_every_2s.txt` -> set `crash_timeout` to 1000ms, 3000ms, 5000ms in `dac.ex`, sends `crash_and_restart`

- `5_servers_follower_crash_and_restart_every_2s.txt` -> set `crash_timeout` to {2: 1000ms, 3: 3000ms, 4: 5000ms} in `dac.ex`, note low max lag, leader did not change

- `5_servers_arbitrary_failure.txt` -> set `crash_timeout` to 1000ms, 3000ms, 5000ms in `dac.ex` {1: 1000ms, 2: 3000ms, 3: 5000ms, 4:7000ms, 5:9000ms} note that server 4 crashed at 7000ms, so it has relatively big max lag at 8000ms, but at 10000ms, the log replication is complete

- `low_election_timeout.txt` -> leader heartbeat 500ms, election timeout 100ms note that term increases more quickly, but it is still hard to get elected as leader, we think it's because voting process up to date check

- `very_low_election_timeout.txt` -> leader heartbeat 500ms, election timeout 80ms note that no leader is ever elected

