module main

import os
import rand
import strings
import time

const capture_limit = 16 * 1024 * 1024

struct ExecutionCase {
	argv       []string
	stdin      string
	cwd        string
	env        map[string]string
	timeout_ms int = 30000
	harness    string
}

struct Command {
	executable        string
	args              []string
	cwd               string
	env               map[string]string
	stdin_path        string
	timeout_ms        int = 30000
	forward_to_stderr bool
}

struct Outcome {
	exit_code int
	stdout    string
	stderr    string
	status    string
}

fn temp_directory() !string {
	path := os.join_path(os.temp_dir(), 'vguard-' + rand.uuid_v4())
	os.mkdir(path)!
	return path
}

fn executable(name string) !string {
	if name.contains('/') || name.contains('\\') {
		path := os.abs_path(name)
		if os.is_file(path) {
			return path
		}
		return error('executable not found: ${path}')
	}
	return os.find_abs_path_of_executable(name) or { error('required executable not found: ${name}') }
}

fn capture(cmd Command) !Outcome {
	mut p := os.new_process(cmd.executable)
	p.set_args(cmd.args)
	p.set_work_folder(cmd.cwd)
	if cmd.env.len > 0 {
		p.set_environment(cmd.env)
	}
	if cmd.stdin_path != '' {
		p.set_stdin_path(cmd.stdin_path)
	} else {
		$if windows {
			p.set_stdin_path('NUL')
		} $else {
			p.set_stdin_path('/dev/null')
		}
	}
	p.set_redirect_stdio()
	$if !windows {
		p.use_pgroup = true
	}
	p.run()
	defer {
		p.close()
	}
	if p.status == .not_started || p.pid <= 0 {
		return error('cannot start ${cmd.executable}: ${p.err}')
	}
	mut out := strings.new_builder(4096)
	mut err := strings.new_builder(4096)
	mut status := ''
	elapsed := time.new_stopwatch()
	for {
		alive := p.is_alive()
		mut read_data := false
		for _ in 0 .. 16 {
			mut read_chunk := false
			if p.is_pending(.stdout) {
				chunk := p.stdout_read()
				out.write_string(chunk)
				if cmd.forward_to_stderr {
					eprint(chunk)
				}
				read_chunk = read_chunk || chunk.len > 0
			}
			if p.is_pending(.stderr) {
				chunk := p.stderr_read()
				err.write_string(chunk)
				if cmd.forward_to_stderr {
					eprint(chunk)
				}
				read_chunk = read_chunk || chunk.len > 0
			}
			if !read_chunk || out.len + err.len > capture_limit {
				break
			}
			read_data = true
		}
		if out.len + err.len > capture_limit {
			status = 'output_limit'
			break
		}
		if elapsed.elapsed().milliseconds() >= cmd.timeout_ms {
			status = 'timeout'
			break
		}
		if !alive && !read_data {
			break
		}
		if !read_data {
			time.sleep(5 * time.millisecond)
		}
	}
	if status != '' && p.is_alive() {
		$if windows {
			p.signal_kill()
		} $else {
			p.signal_pgkill()
		}
	}
	p.wait()
	if status == '' {
		status = if p.status == .aborted { 'signal' } else { 'exited' }
	}
	return Outcome{
		exit_code: p.code
		stdout:    out.str()
		stderr:    err.str()
		status:    status
	}
}

fn (scenario &ExecutionCase) environment() map[string]string {
	mut env := os.environ()
	for name, value in scenario.env {
		env[name] = value
	}
	return env
}

fn (scenario &ExecutionCase) run_binary(path string) !Outcome {
	work := temp_directory()!
	defer {
		os.rmdir_all(work) or {}
	}
	input := os.join_path(work, 'stdin')
	os.write_file(input, scenario.stdin)!
	return capture(Command{
		executable: path
		args:       scenario.argv
		cwd:        scenario.cwd
		env:        scenario.environment()
		stdin_path: input
		timeout_ms: scenario.timeout_ms
	})
}
