import os
import sys
import json
import time
import subprocess
import requests

ROOT_DIR = "/home/hermes/llama"
SYMPY_DIR = "/home/hermes/llama/scratch/sympy"
PREDICTIONS_DIR = "/home/hermes/llama/scratch/predictions"

QWEN_MODEL_PATH = "/home/hermes/llama/models/unsloth-mtp-q4km/Qwen3.6-27B-Q4_K_M.gguf"
GEMMA_MODEL_PATH = "/home/hermes/llama/models/gemma-4-31b-qat-mtp/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"

QWEN_MODEL_ID = "Qwen3.6-27B-Q4_K_M.gguf"
GEMMA_MODEL_ID = "gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"

PROBLEM_STATEMENT = """Symbol instances have __dict__ since 1.7?
In version 1.6.2 Symbol instances had no `__dict__` attribute
>>> sympy.Symbol('s').__dict__
AttributeError: 'Symbol' object has no attribute '__dict__'
>>> sympy.Symbol('s').__slots__
('name',)

This changes in 1.7 where `sympy.Symbol('s').__dict__` now exists (and returns an empty dict)
I assume this is a bug, introduced because some parent class accidentally stopped defining `__slots__`."""

PROMPT = f"""Please solve the following issue where Symbol instances have __dict__ since 1.7, which is a bug because some parent class accidentally stopped defining __slots__.
In version 1.6.2 Symbol instances had no __dict__ attribute.
Make sure Symbol has no __dict__ attribute and defines __slots__ correctly.

Issue description:
{PROBLEM_STATEMENT}"""

os.makedirs(PREDICTIONS_DIR, exist_ok=True)

def run_cmd(args, cwd=None, input_text=None, capture=True):
    print(f"Running command: {' '.join(args)} in cwd={cwd}")
    stdout_option = subprocess.PIPE if capture else None
    stderr_option = subprocess.PIPE if capture else None
    res = subprocess.run(args, cwd=cwd, input=input_text, stdout=stdout_option, stderr=stderr_option, text=True)
    if res.returncode != 0:
        print(f"Command failed with code {res.returncode}")
        if capture:
            print(f"STDOUT:\n{res.stdout}")
            print(f"STDERR:\n{res.stderr}")
    return res

def stop_qwen():
    print("Stopping Qwen service...")
    run_cmd(["sudo", "systemctl", "stop", "llama-server.service"])

def start_qwen():
    print("Starting Qwen service...")
    run_cmd(["sudo", "systemctl", "start", "llama-server.service"])
    wait_ready()

def stop_gemma():
    print("Stopping Gemma service...")
    run_cmd(["bash", f"{ROOT_DIR}/scripts/stop-gemma4-qat.sh"])

def start_gemma():
    print("Starting Gemma service...")
    # This automatically stops Qwen service
    run_cmd(["bash", f"{ROOT_DIR}/scripts/start-gemma4-qat.sh"])

def wait_ready(timeout=300):
    url = "http://127.0.0.1:8080/v1/models"
    print(f"Waiting for llama-server readiness at {url}...")
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            r = requests.get(url, timeout=3)
            if r.status_code == 200:
                print("✓ Server is ready!")
                return
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError("Server failed to start within timeout")

def run_llama_bench(model_path, model_name):
    print(f"Running llama-bench on {model_name}...")
    # We offload all layers, use flash attention, q4_0 cache, and depths 0, 2000, 4000, 8000
    cmd = [
        "llama-bench",
        "-m", model_path,
        "-ngl", "99",
        "-fa", "on",
        "-ctk", "q4_0",
        "-ctv", "q4_0",
        "-p", "512",
        "-n", "128",
        "-d", "0,2000,4000,8000",
        "-o", "md"
    ]
    res = run_cmd(cmd)
    return res.stdout

def run_pi_harness(model_id, prompt):
    print(f"Running Pi harness on {model_id}...")
    # Reset sympy repo
    run_cmd(["git", "reset", "--hard"], cwd=SYMPY_DIR)
    run_cmd(["git", "clean", "-fdx"], cwd=SYMPY_DIR)
    run_cmd(["git", "checkout", "cffd4e0f86fefd4802349a9f9b19ed70934ea354"], cwd=SYMPY_DIR)

    # Run pi
    cmd = [
        "pi",
        "--provider", "llamacpp",
        "--model", model_id,
        "--no-session",
        "-p", prompt
    ]
    # We do not capture output of pi to see it in real-time, or let it run
    res = run_cmd(cmd, cwd=SYMPY_DIR, capture=False)

    # Retrieve git diff
    diff_res = run_cmd(["git", "diff"], cwd=SYMPY_DIR)
    return diff_res.stdout

def write_predictions(instance_id, patch, model_name, filename):
    filepath = os.path.join(PREDICTIONS_DIR, filename)
    with open(filepath, "w") as f:
        data = {
            "instance_id": instance_id,
            "model_patch": patch,
            "model_name_or_path": model_name
        }
        f.write(json.dumps(data) + "\n")
    print(f"Written predictions to {filepath}")
    return filepath

def run_swebench_eval(pred_file, run_id):
    print(f"Running SWE-bench evaluation for {run_id}...")
    cmd = [
        "sudo", "python3", "-m", "swebench.harness.run_evaluation",
        "--predictions_path", pred_file,
        "--max_workers", "1",
        "--instance_ids", "sympy__sympy-20590",
        "--run_id", run_id
    ]
    # Run evaluation and capture stdout
    res = run_cmd(cmd, capture=True)
    return res.stdout, res.stderr

def main():
    print("=== STARTING BENCHMARKS ===")
    
    # 1. Native llama-bench Qwen
    stop_qwen()
    stop_gemma()
    qwen_bench_out = run_llama_bench(QWEN_MODEL_PATH, "Qwen 27B")
    print("--- Qwen Native Bench Result ---")
    print(qwen_bench_out)
    
    # 2. Pi / SWE-bench task Qwen
    start_qwen()
    qwen_patch = run_pi_harness(QWEN_MODEL_ID, PROMPT)
    print("--- Qwen Generated Patch ---")
    print(qwen_patch)
    qwen_pred_file = write_predictions("sympy__sympy-20590", qwen_patch, "Qwen27B", "predictions_qwen.jsonl")
    
    # 3. Native llama-bench Gemma
    stop_qwen()
    gemma_bench_out = run_llama_bench(GEMMA_MODEL_PATH, "Gemma 31B")
    print("--- Gemma Native Bench Result ---")
    print(gemma_bench_out)
    
    # 4. Pi / SWE-bench task Gemma
    start_gemma()
    gemma_patch = run_pi_harness(GEMMA_MODEL_ID, PROMPT)
    print("--- Gemma Generated Patch ---")
    print(gemma_patch)
    gemma_pred_file = write_predictions("sympy__sympy-20590", gemma_patch, "Gemma31B", "predictions_gemma.jsonl")
    
    # 5. Stop Gemma & Restore Qwen (original state)
    stop_gemma()
    start_qwen()
    
    # 6. Run SWE-bench Evaluations
    print("--- Running SWE-bench Evaluation for Qwen ---")
    qwen_eval_out, qwen_eval_err = run_swebench_eval(qwen_pred_file, "eval-qwen")
    print("STDOUT:\n", qwen_eval_out)
    print("STDERR:\n", qwen_eval_err)
    
    print("--- Running SWE-bench Evaluation for Gemma ---")
    gemma_eval_out, gemma_eval_err = run_swebench_eval(gemma_pred_file, "eval-gemma")
    print("STDOUT:\n", gemma_eval_out)
    print("STDERR:\n", gemma_eval_err)
    
    # Save raw outputs for logs/reference
    with open(f"{ROOT_DIR}/benchmark/qwen_bench_native.md", "w") as f:
        f.write(qwen_bench_out)
    with open(f"{ROOT_DIR}/benchmark/gemma_bench_native.md", "w") as f:
        f.write(gemma_bench_out)
        
    print("=== BENCHMARKS COMPLETE ===")

if __name__ == "__main__":
    main()
