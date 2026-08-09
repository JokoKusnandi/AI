import numpy as np
from qiskit import QuantumCircuit, transpile
from qiskit_aer import AerSimulator
from qiskit.visualization import plot_histogram

# 1. Tentukan Kata Sandi Rahasia (Target)
# Dalam simulasi ini, kita anggap password adalah '101' (3 bit)
secret_password = '101'
n_qubits = len(secret_password)

# 2. Membuat Sirkuit Kuantum
qc = QuantumCircuit(n_qubits, n_qubits)

# 3. Langkah Superposisi (Hadamard Gate)
# Membuat qubit berada di semua kemungkinan state sekaligus
qc.h(range(n_qubits))

# 4. Oracle (Penanda Kata Sandi)
# Ini adalah bagian "ajaib" yang menandai jawaban yang benar.
# Dalam kasus nyata, oracle ini adalah fungsi hash yang kompleks.
# Di sini kita simulasikan dengan gerbang X dan Z.
for i, bit in enumerate(secret_password):
    if bit == '0':
        qc.x(i) # Balikkan jika targetnya 0 agar menjadi 1

qc.cz(0, 1) # Contoh interaksi antar qubit (kontrol-Z)
# (Catatan: Implementasi oracle penuh sangat kompleks, ini versi simplifikasi logika)

for i, bit in enumerate(secret_password):
    if bit == '0':
        qc.x(i) # Kembalikan ke kondisi awal

# 5. Diffuser (Amplifikasi Amplitudo)
# Meningkatkan probabilitas menemukan state yang ditandai oleh Oracle
qc.h(range(n_qubits))
qc.x(range(n_qubits))
qc.h(n_qubits - 1)
# qc.mct(list(range(n_qubits - 1)), n_qubits - 1) # Multi-controlled Toffoli
qc.mcx(list(range(n_qubits - 1)), n_qubits - 1) # Multi-controlled X (Toffoli)
qc.h(n_qubits - 1)
qc.x(range(n_qubits))
qc.h(range(n_qubits))

# 6. Pengukuran
qc.measure(range(n_qubits), range(n_qubits))

# 7. Eksekusi Simulasi
simulator = AerSimulator()
compiled_circuit = transpile(qc, simulator)
job = simulator.run(compiled_circuit, shots=1024)
result = job.result()
counts = result.get_counts()

# 8. Hasil
print(f"Hasil Simulasi Pencarian Password '{secret_password}':")
print(counts)

# Visualisasi
plot_histogram(counts).show()