# Ini adalah simulasi konseptual. 
# Dalam kenyataannya, 'oracle' harus berupa fungsi hash kriptografi nyata (seperti SHA-256)
# yang diimplementasikan sebagai sirkuit kuantum, yang sangat kompleks.

from qiskit import QuantumCircuit, transpile
from qiskit_aer import Aer
from qiskit.visualization import plot_histogram
import numpy as np

def simulate_grover_on_hash(target_hash_bits):
    """
    Simulasi Grover untuk mencari input yang cocok dengan target hash.
    """
    n = len(target_hash_bits) # Jumlah qubit sesuai panjang hash (disederhanakan)
    qc = QuantumCircuit(n, n)
    
    # 1. Superposisi
    qc.h(range(n))
    
    # 2. Oracle (Menandai jawaban yang benar)
    # Di dunia nyata, ini adalah sirkuit yang menghitung hash dan membandingkannya
    for i in range(n):
        if target_hash_bits[i] == '0':
            qc.x(i)
    qc.mcx(list(range(n-1)), n-1) # Multi-controlled Toffoli sebagai penanda
    for i in range(n):
        if target_hash_bits[i] == '0':
            qc.x(i)
            
    # 3. Diffuser
    qc.h(range(n))
    qc.x(range(n))
    qc.h(n-1)
    qc.mcx(list(range(n-1)), n-1)
    qc.h(n-1)
    qc.x(range(n))
    qc.h(range(n))
    
    # 4. Ukur
    qc.measure(range(n), range(n))
    
    # Eksekusi
    simulator = Aer.get_backend('qasm_simulator')
   # 1. Transpile sirkuit agar sesuai dengan target simulator
    compiled_circuit = transpile(qc, simulator)

    # 2. Jalankan simulasi menggunakan backend.run()
    result = simulator.run(compiled_circuit, shots=1024).result()

    return result.get_counts()

# Contoh: Mencari password 3-bit yang hash-nya adalah '101'
print(simulate_grover_on_hash('101'))