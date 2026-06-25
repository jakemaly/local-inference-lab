import os
import sys
import json
import time
import subprocess
import requests

ROOT_DIR = "/home/hermes/llama"
SYMPY_DIR = "/home/hermes/llama/scratch/sympy"
PREDICTIONS_DIR = "/home/hermes/llama/scratch/predictions"

QWEN_MODEL_ID = "Qwen3.6-27B-Q4_K_M.gguf"
GEMMA_MODEL_ID = "gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"

INSTANCES = [
    {
        "instance_id": "sympy__sympy-20590",
        "base_commit": "cffd4e0f86fefd4802349a9f9b19ed70934ea354",
        "problem_statement": """Symbol instances have __dict__ since 1.7?
In version 1.6.2 Symbol instances had no `__dict__` attribute
>>> sympy.Symbol('s').__dict__
AttributeError: 'Symbol' object has no attribute '__dict__'
>>> sympy.Symbol('s').__slots__
('name',)

This changes in 1.7 where `sympy.Symbol('s').__dict__` now exists (and returns an empty dict)
I assume this is a bug, introduced because some parent class accidentally stopped defining `__slots__`."""
    },
    {
        "instance_id": "sympy__sympy-24443",
        "base_commit": "809c53c077485ca48a206cee78340389cb83b7f1",
        "problem_statement": """`_check_homomorphism` is broken on PermutationGroups
```python
In [1]: from sympy.combinatorics import *
   ...: from sympy.combinatorics.homomorphisms import homomorphism
   ...: D3 = DihedralGroup(3)
   ...: T = homomorphism(D3, D3, D3.generators, D3.generators)

ValueError: The given images do not define a homomorphism
```

The issue is in the internal `_image()` function, where it handles the case of a `PermutationGroup`:

https://github.com/sympy/sympy/blob/809c53c077485ca48a206cee78340389cb83b7f1/sympy/combinatorics/homomorphisms.py#L336-L337

When `r[i]` is an inverted generator, the `in gens` test fails.

I think the whole thing can be greatly simplified."""
    },
    {
        "instance_id": "sympy__sympy-13974",
        "base_commit": "84c125972ad535b2dfb245f8d311d347b45e5b8a",
        "problem_statement": """Evaluating powers of `TensorProduct`
Powers of tensor product expressions are not possible to evaluate with either `expand(tensorproduct=True)` method nor the `tensor_product_simp`function.

This is an example session showing the issue
```
In [1]: from sympy import *
        from sympy.physics.quantum import TensorProduct as tp
        from sympy.physics.quantum import tensor_product_simp as tps
        from sympy.physics.paulialgebra import Pauli
        a = Symbol('a', commutative=False)

In [2]: t1 = tp(1,1)*tp(1,1)
        t1
Out[2]: 1x1**2

In [3]: tps(t1)
Out[3]: 1x1**2

In [4]: t1.expand(tensorproduct=True)
Out[4]: 1x1**2

In [5]: tps(tp(1,1)*tp(1,a)).subs(a, 1)
Out[5]: 1x1

In [6]: t2 = tp(1,Pauli(3))*tp(1,Pauli(3))
        t2
Out[6]: 1xsigma3**2

In [7]: tps(t2)
Out[7]: 1xsigma3**2

In [8]: t2.expand(tensorproduct=True)
Out[8]: 1xsigma3**2

In [9]: tps(tp(1,Pauli(3))*tp(1,a)).subs(a, Pauli(3))
Out[9]: 1x1
```
where `[5]` and `[9]` shows expected result for `t1` and `t2` respectively."""
    },
    {
        "instance_id": "sympy__sympy-14248",
        "base_commit": "9986b38181cdd556a3f3411e553864f11912244e",
        "problem_statement": """The difference of MatrixSymbols prints as a sum with (-1) coefficient
Internally, differences like a-b are represented as the sum of a with `(-1)*b`, but they are supposed to print like a-b. This does not happen with MatrixSymbols. I tried three printers: str, pretty, and latex: 
```
from sympy import *
A = MatrixSymbol('A', 2, 2)
B = MatrixSymbol('B', 2, 2)
print(A - A*B - B)
pprint(A - A*B - B)
latex(A - A*B - B)
```
Output:
```
(-1)*B + (-1)*A*B + A
-B + -A⋅B + A
'-1 B + -1 A B + A'
```"""
    },
    {
        "instance_id": "sympy__sympy-13877",
        "base_commit": "1659712001810f5fc563a443949f8e3bb38af4bd",
        "problem_statement": """Matrix determinant raises Invalid NaN comparison with particular symbolic entries
    >>> from sympy import *
    >>> from sympy.abc import a
    >>> f = lambda n: det(Matrix([[i + a*j for i in range(n)] for j in range(n)]))
    >>> f(1)
    0
    >>> f(2)
    -a
    >>> f(3)
    2*a*(a + 2) + 2*a*(2*a + 1) - 3*a*(2*a + 2)
    >>> f(4)
    0
    >>> f(5)
    nan
    >>> f(6)
    Traceback (most recent call last):
      File "<pyshell#4>", line 1, in <module>
            f(6)
      ...
      File "C:\\Users\\E\\AppData\\Local\\Programs\\Python\\Python36\\lib\\site-packages\\sympy\\core\\expr.py", line 323, in __lt__
            raise TypeError("Invalid NaN comparison")
    TypeError: Invalid NaN comparison

Correct me if I'm wrong but isn't the Bareiss algorithm only valid for integer matrices, which cannot be assumed here?"""
    }
]

os.makedirs(PREDICTIONS_DIR, exist_ok=True)

def run_cmd(args, cwd=None, capture=True):
    print(f"Running: {' '.join(args)} in cwd={cwd}")
    stdout_option = subprocess.PIPE if capture else None
    stderr_option = subprocess.PIPE if capture else None
    res = subprocess.run(args, cwd=cwd, stdout=stdout_option, stderr=stderr_option, text=True)
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
    run_cmd(["bash", f"{ROOT_DIR}/scripts/start-gemma4-qat.sh"])

def wait_ready(timeout=300):
    url = "http://127.0.0.1:8080/v1/models"
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

def run_pi_on_instance(model_id, inst):
    print(f"\n>>> Running Pi on {inst['instance_id']} using {model_id}...")
    # Reset sympy repo to base_commit
    run_cmd(["git", "reset", "--hard"], cwd=SYMPY_DIR)
    run_cmd(["git", "clean", "-fdx"], cwd=SYMPY_DIR)
    run_cmd(["git", "checkout", inst["base_commit"]], cwd=SYMPY_DIR)
    
    prompt = f"Please solve the following issue in the repository:\n\n{inst['problem_statement']}"
    
    # Run pi coding harness
    cmd = [
        "pi",
        "--provider", "llamacpp",
        "--model", model_id,
        "--no-session",
        "-p", prompt
    ]
    # Execute non-interactively
    run_cmd(cmd, cwd=SYMPY_DIR, capture=False)
    
    # Capture diff
    diff_res = run_cmd(["git", "diff"], cwd=SYMPY_DIR)
    return diff_res.stdout

def write_predictions_batch(predictions, filename):
    filepath = os.path.join(PREDICTIONS_DIR, filename)
    with open(filepath, "w") as f:
        for pred in predictions:
            f.write(json.dumps(pred) + "\n")
    print(f"Written batch predictions to {filepath}")
    return filepath

def run_swebench_eval_batch(pred_file, instance_ids, run_id):
    print(f"Running SWE-bench evaluation for {run_id}...")
    cmd = [
        "sudo", "python3", "-m", "swebench.harness.run_evaluation",
        "--predictions_path", pred_file,
        "--max_workers", "1",
        "--instance_ids", ",".join(instance_ids),
        "--run_id", run_id
    ]
    res = run_cmd(cmd, capture=True)
    return res.stdout, res.stderr

def main():
    print("=== STARTING BATCH EVALUATION ===")
    instance_ids = [inst["instance_id"] for inst in INSTANCES]
    
    # --- 1. Evaluate Qwen 27B ---
    start_qwen()
    qwen_predictions = []
    for inst in INSTANCES:
        patch = run_pi_on_instance(QWEN_MODEL_ID, inst)
        qwen_predictions.append({
            "instance_id": inst["instance_id"],
            "model_patch": patch,
            "model_name_or_path": "Qwen27B"
        })
    qwen_pred_file = write_predictions_batch(qwen_predictions, "batch_predictions_qwen.jsonl")
    
    # --- 2. Evaluate Gemma 31B ---
    start_gemma()
    gemma_predictions = []
    for inst in INSTANCES:
        patch = run_pi_on_instance(GEMMA_MODEL_ID, inst)
        gemma_predictions.append({
            "instance_id": inst["instance_id"],
            "model_patch": patch,
            "model_name_or_path": "Gemma31B"
        })
    gemma_pred_file = write_predictions_batch(gemma_predictions, "batch_predictions_gemma.jsonl")
    
    # --- 3. Stop Gemma & Restore Qwen (original state) ---
    stop_gemma()
    start_qwen()
    
    # --- 4. Run SWE-bench Grading ---
    print("\n--- GRADING QWEN BATCH ---")
    qwen_stdout, qwen_stderr = run_swebench_eval_batch(qwen_pred_file, instance_ids, "batch-qwen")
    print("Qwen Grading STDOUT:\n", qwen_stdout)
    
    print("\n--- GRADING GEMMA BATCH ---")
    gemma_stdout, gemma_stderr = run_swebench_eval_batch(gemma_pred_file, instance_ids, "batch-gemma")
    print("Gemma Grading STDOUT:\n", gemma_stdout)
    
    # Save grading outputs
    with open(f"{ROOT_DIR}/benchmark/qwen_batch_eval_out.txt", "w") as f:
        f.write(qwen_stdout)
        f.write("\n\n=== STDERR ===\n\n")
        f.write(qwen_stderr)
        
    with open(f"{ROOT_DIR}/benchmark/gemma_batch_eval_out.txt", "w") as f:
        f.write(gemma_stdout)
        f.write("\n\n=== STDERR ===\n\n")
        f.write(gemma_stderr)
        
    print("=== BATCH EVALUATION COMPLETE ===")

if __name__ == "__main__":
    main()
