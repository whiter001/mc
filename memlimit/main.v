module main

import os
import time

struct ProcInfo {
	ppid int
	rss  int
}

fn main() {
	if os.args.len >= 2 && os.args[1] in ['-h', '--help', 'help'] {
		help()
		exit(0)
	}
	if os.args.len < 3 {
		usage()
		exit(2)
	}
	limit_mb := os.args[1].int()
	if limit_mb <= 0 {
		usage()
		exit(2)
	}
	cmd := os.args[2]

	mut p := os.new_process(cmd)
	p.set_args(os.args[3..])
	p.run()

	limit_kb := limit_mb * 1024
	for {
		if !p.is_alive() {
			p.wait()
			exit(p.code)
		}
		res := os.execute('ps -axo pid=,ppid=,rss=')
		procs := parse_ps(res.output)
		rss_kb := tree_rss_kb(p.pid, procs)
		if rss_kb > limit_kb {
			eprintln('memlimit: pid ${p.pid} exceeded memory limit (RSS ${rss_kb} KB > limit ${limit_kb} KB = ${limit_mb} MB)')
			p.signal_kill()
			exit(1)
		}
		time.sleep(50 * time.millisecond)
	}
}

// parse_ps parses `ps -axo pid=,ppid=,rss=` output into a pid -> (ppid, rss) map.
// Blank/broken lines are skipped; a process that vanished mid-snapshot is simply
// not part of the map, which callers handle gracefully.
fn parse_ps(out string) map[int]ProcInfo {
	mut procs := map[int]ProcInfo{}
	for line in out.trim_space().split('\n') {
		fields := line.fields()
		if fields.len < 3 {
			continue
		}
		pid := fields[0].int()
		if pid <= 0 {
			continue
		}
		procs[pid] = ProcInfo{
			ppid: fields[1].int()
			rss:  fields[2].int()
		}
	}
	return procs
}

// tree_rss_kb returns the sum of the RSS of root_pid and all its descendants.
fn tree_rss_kb(root_pid int, procs map[int]ProcInfo) int {
	mut total := 0
	mut visited := map[int]bool{}
	mut queue := [root_pid]
	visited[root_pid] = true
	for queue.len > 0 {
		pid := queue[0]
		queue.delete(0)
		if info := procs[pid] {
			total += info.rss
		}
		for child_pid, info in procs {
			if !visited[child_pid] && info.ppid == pid {
				visited[child_pid] = true
				queue << child_pid
			}
		}
	}
	return total
}

fn usage() {
	eprintln('usage: memlimit <limit_mb> <cmd> [args...]')
	eprintln("run 'memlimit --help' for more information")
}

fn help() {
	println('usage: memlimit <limit_mb> <cmd> [args...]
Run <cmd> with its [args...] under a memory limit applied to the
summed RSS of the whole process tree (the command and all descendants).

Arguments:
  limit_mb  memory limit in MB; compared against the tree RSS sum in KB every 50 ms
  cmd       command to run
  args...   arguments for the command

When the tree RSS sum exceeds the limit, the tree is killed with SIGKILL
and memlimit exits with code 1.

Exit codes:
  0       the command finished within the limit
  1       the process tree exceeded the limit and was killed
  2       usage error
  other   the exit code of the command, passed through

Example:
  ./memlimit 500 python3 train.py')
}
