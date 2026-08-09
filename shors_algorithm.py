import numpy as np
from qiskit import QuantumCircuit, transpile
from qiskit_aer import AerSimulator
from fractions import Fraction
import math

def shors_algorithm(N):
    """
    Simulasi sederhana Algoritma Shor untuk memfaktorkan N.
    N haruslah bilangan komposit ganjil.
    """
    print(f"Memulai pemfaktoran untuk N = {N}")
    
    # Langkah 1: Pilih angka acak 'a' yang relatif prima terhadap N
    a = 2 
    if math.gcd(a, N) != 1:
        print(f"Faktor ditemukan langsung: {math.gcd(a, N)}")
        return

    # Langkah 2: Mencari periode 'r' dari fungsi f(x) = a^x mod N
    # Di komputer kuantum, ini dilakukan menggunakan Quantum Fourier Transform (QFT)
    # Untuk simulasi ini, kita akan mensimulasikan hasil pengukuran QFT
    
    # Jumlah qubit yang dibutuhkan (log2(N) dibulatkan ke atas)
    n = N.bit_length()
    t = 2 * n # Jumlah qubit untuk register pertama (estimasi fase)
    
    # Membuat sirkuit kuantum
    qc = QuantumCircuit(t + n, t)
    
    # Inisialisasi superposisi pada register pertama
    qc.h(range(t))
    
    # Implementasi Modular Exponentiation (Sangat kompleks, disederhanakan untuk simulasi)
    # Dalam implementasi nyata, ini melibatkan banyak gerbang terkontrol.
    # Di sini kita asumsikan sirkuit oracle sudah siap.
    
    # Quantum Fourier Transform (QFT) Inverse
    for k in range(t):
        for j in range(k):
            qc.cp(-np.pi / float(2**(k-j)), j, k)
        qc.h(k)
        
    # Mengukur register pertama
    qc.measure(range(t), range(t))
    
    # Eksekusi Simulasi
    simulator = AerSimulator()
    compiled_circuit = transpile(qc, simulator)
    job = simulator.run(compiled_circuit, shots=1024)
    result = job.result()
    counts = result.get_counts()
    
    # Langkah 3: Klasik Post-Processing (Mencari periode dari hasil pengukuran)
    # Kita ambil hasil pengukuran yang paling sering muncul
    measured_value = max(counts, key=counts.get)
    decimal_value = int(measured_value, 2)
    
    # Estimasi fase s/r
    phase = decimal_value / (2**t)
    fraction = Fraction(phase).limit_denominator(N)
    r = fraction.denominator
    
    print(f"Periode (r) yang diperkirakan: {r}")
    
    # Langkah 4: Menghitung Faktor
    if r % 2 == 0 and pow(a, r // 2, N) != N - 1:
        factor1 = math.gcd(pow(a, r // 2) - 1, N)
        factor2 = math.gcd(pow(a, r // 2) + 1, N)
        
        if factor1 > 1 and factor2 > 1:
            print(f"SUAKSES! Faktor dari {N} adalah: {factor1} dan {factor2}")
        else:
            print("Gagal menemukan faktor, coba lagi dengan 'a' yang berbeda.")
    else:
        print("Periode tidak valid, coba lagi.")

# Jalankan algoritma untuk angka 15
shors_algorithm(15)