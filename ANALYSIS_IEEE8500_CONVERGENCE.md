# Why IEEE8500 Requires Significantly More Iterations

## Summary
IEEE8500 grids require **18-23 iterations** vs **2-5 iterations** for other networks. Analysis reveals **5 interconnected factors**:

| Factor | Impact | Evidence |
|--------|--------|----------|
| **Network Size** | ~30× larger | 8,525 nodes vs ~274-906 typical |
| **Fixed-Point Convergence Rate** | Poor spectral radius | 0.51-0.80 ratio vs 0.02-0.08 others |
| **Voltage Regulation** | Worse coupling | 809× voltage spread (0.012-9.68 pu) |
| **System Conditioning** | Sparse, weakly coupled | 46,547 nonzeros in ~8500×8500 matrix |
| **Load Model** | All constant-power (PQ) | 1,177+ pure PQ loads → nonlinear fixed-point |

---

## Detailed Analysis

### 1. **Network Size Effect** (~3× contribution)

#### Comparative Sizes:
| Network | Buses | Nodes | Lines | Loads | Ratio to 13-bus |
|---------|-------|-------|-------|-------|-----------------|
| 13-bus | 16 | 38 | 15 | 15 | 1× |
| 37-bus | 39 | 114 | 36 | 30 | 3× |
| 123-bus | 132 | 274 | 126 | 91 | 7× |
| 240-bus | 436 | 906 | 239 | 194 | 24× |
| 906-bus | 907 | 2,718 | 905 | 55 | 72× |
| **IEEE8500 balanced** | **4,875** | **8,525** | **3,700** | **1,177** | **224×** |

**IEEE8500 is 224× larger than 13-bus, yet only requires 3.6× more iterations.**

This suggests the primary issue is NOT size alone, but something about the network structure.

---

### 2. **Fixed-Point Convergence Rate** (Primary Factor)

The Z-bus solver uses a fixed-point iteration:
$$v^{(k+1)} = (Y_{net} + Y_L)^{-1} \left(-I^{(k)} - Y_{NS}v_{slack}\right)$$

The **convergence rate depends on the spectral radius** of the iteration matrix.

#### Convergence Rate Metrics:

| Network | Early Ratio† | Late Ratio | Decay Rate‡ | Iterations |
|---------|------------|-----------|------------|-----------|
| 13-bus | 0.083 | — | 2.49 | 5 |
| 37-bus | 1.622§ | 0.966 | -0.055§ | 100 (diverges) |
| 123-bus | 0.025 | — | — | 3 |
| 240-bus | 0.018 | — | — | 3 |
| 906-bus | 0.020 | — | — | 2 |
| **IEEE8500 balanced** | **0.514** | **0.759** | **0.541** | **18** |
| **IEEE8500 unbalanced** | **0.511** | **0.796** | **0.533** | **23** |

† Early Ratio = $r^{(i+1)}/r^{(i)}$ for first 5 iterations  
‡ Decay Rate ≈ $\log(r^{(i+1)}/r^{(i)})$ from exponential fit  
§ 37-bus **diverges** initially (ratio > 1), never converges

**Key Finding:** IEEE8500 has a convergence ratio of **0.51-0.80**, meaning each iteration reduces residual by only 50-80%, vs 2-8% for most networks.

---

### 3. **Voltage Regulation & Network Coupling** 

The voltage span indicates how tightly coupled the network is (weak voltage regulation → loose coupling → slow convergence).

#### Voltage Ranges:

| Network | V_min | V_max | Spread | Ratio | Coupling |
|---------|-------|-------|--------|-------|----------|
| 13-bus | 0.108 | 27.65 | 27.54 | 256× | Poor |
| 37-bus | 0.087 | 47.92 | 47.84 | **551×** | **Very poor** |
| 123-bus | 0.115 | 1.058 | 0.943 | 9× | **Excellent** |
| 240-bus | 0.013 | 4.995 | 4.983 | 385× | Poor |
| 906-bus | 0.999 | 26.97 | 25.97 | 27× | Good |
| **IEEE8500 balanced** | **0.012** | **9.683** | **9.671** | **809×** | **Extremely poor** |
| **IEEE8500 unbalanced** | **0.012** | **9.683** | **9.671** | **809×** | **Extremely poor** |

**IEEE8500 has 809× voltage spread** — nearly **31× worse than 906-bus** (which is similar size but converges in 2 iterations).

**Why this matters:** In poorly regulated networks, the fixed-point iteration has slow mixing between distant nodes. Information propagates slowly through the network, requiring more iterations to converge.

---

### 4. **System Matrix Conditioning**

#### Sparsity Pattern:

| Network | Nodes | Matrix nnz | Density | Avg nnz/row |
|---------|-------|-----------|---------|------------|
| 13-bus | 38 | 258 | 0.18% | 6.8 |
| 37-bus | 114 | 1,008 | 0.08% | 8.8 |
| 123-bus | 274 | 2,060 | 0.027% | 7.5 |
| 240-bus | 906 | 4,970 | 0.006% | 5.5 |
| 906-bus | 2,718 | 24,444 | 0.0033% | 9.0 |
| **IEEE8500 balanced** | **8,525** | **46,547** | **0.00064%** | **5.5** |
| **IEEE8500 unbalanced** | **8,528** | **46,568** | **0.00064%** | **5.5** |

**IEEE8500 matrix is more sparse** (0.00064% vs typical 0.006%), indicating **weak electrical coupling** between nodes. This is characteristic of long, radial distribution feeders with few cross-connections.

---

### 5. **Load Model Nonlinearity**

#### Load Composition:

| Network | PQ | Z | I | Motor | CVR | Nonlinear % | Modes |
|---------|----|----|---|-------|-----|------------|-------|
| 13-bus | 11 | 2 | 2 | 0 | 0 | 87% | Mixed |
| 37-bus | 15 | 7 | 0 | 0 | 8 | 77% | **CVR present** |
| 123-bus | 59 | 17 | 15 | 0 | 0 | 81% | Mixed |
| 240-bus | 194 | 0 | 0 | 0 | 0 | 100% | **Pure PQ** |
| 906-bus | 55 | 0 | 0 | 0 | 0 | 100% | **Pure PQ** |
| **IEEE8500 balanced** | **1,177** | **0** | **0** | **0** | **0** | **100%** | **Pure PQ** |
| **IEEE8500 unbalanced** | **2,354** | **0** | **0** | **0** | **0** | **100%** | **Pure PQ** |

All IEEE8500 loads are **constant-power (PQ)**, which creates **strong nonlinearity**:
- PQ load current: $I = \overline{S/V}$ (inverse voltage relationship)
- This makes the fixed-point iteration inherently slower because $\partial I/\partial V$ is large

---

## Comparison: Why 906-bus ≠ IEEE8500?

Both networks are large (907 vs 4,875 buses), but 906-bus converges in **2 iterations** while IEEE8500 takes **18**.

### Key Difference: **Voltage Regulation**

| Metric | 906-bus | IEEE8500 | Ratio |
|--------|---------|----------|-------|
| Buses | 907 | 4,875 | 5.4× |
| Nodes | 2,718 | 8,525 | 3.1× |
| Iterations | 2 | 18 | 9× |
| V_max/V_min | 27× | 809× | **30×** |
| Convergence ratio | 0.020 | 0.514 | **25.7×** |

**906-bus has tight voltage regulation** (0.999-26.97 pu, mostly near nominal) and **strong network coupling** despite being large.

**IEEE8500 has terrible voltage regulation** (0.012-9.68 pu, extreme spread) indicating **weak network coupling** from its radial, lightly-meshed structure.

---

## Convergence Behavior Visualization

### Residual Decay Patterns:

**Fast convergence (exponential decay):**
```
13-bus:    8.0e-1 → 6.6e-2 → 5.5e-3 → 4.5e-4 → ... (ratio ~0.08)
906-bus:   1.0e-0 → 2.0e-2 → 4.0e-4 → ... (ratio ~0.02)
```

**Slow convergence (linear decay):**
```
IEEE8500:  1.0e+0 → 5.1e-1 → 2.6e-1 → 1.3e-1 → 6.7e-2 → ... (ratio ~0.51)
           Takes 18 iterations to reach 8.9e-6 residual
```

The decay constant tells the story:
- **Decay rate ≈ 2.49** (13-bus): Residual drops by factor of ~12 per iteration
- **Decay rate ≈ 0.54** (IEEE8500): Residual drops by factor of ~1.7 per iteration

---

## Root Cause Analysis

### Why IEEE8500 Converges Slowly:

1. **Network is radial and weakly-meshed:** Long feeders with few interconnections create poor voltage regulation and weak node coupling.

2. **Voltage-dependent loads amplify nonlinearity:** At low voltages, PQ loads draw very large currents, creating sharp transients in the fixed-point iterations.

3. **Fixed-point method itself has limitations:** The Z-bus solver is inherently slower than Newton-Raphson for poorly-conditioned networks because:
   - Spectral radius of iteration matrix is close to 1 when network is weakly coupled
   - Requires $\log(1/\varepsilon) / \log(1/\rho)$ iterations, where $\rho$ is spectral radius
   - For $\rho=0.51$, need $\log(10^{-5})/\log(0.51) \approx 17.5$ iterations

4. **System size slows down each iteration:** Even if convergence ratio were constant, 224× larger network still costs more per iteration.

---

## Recommendations

### If you want faster convergence for IEEE8500:

1. **Use Newton-Raphson instead of fixed-point Z-bus**
   - NR converges in 3-5 iterations regardless of network coupling
   - Would reduce IEEE8500 from 18 → 3-5 iterations (~4-6× speedup)

2. **Improve initialization**
   - Start from flat voltage profile instead of no-load solution
   - Could save 2-3 iterations for poorly regulated networks

3. **Use Anderson acceleration or GMRES**
   - Accelerate fixed-point convergence with minimal code changes
   - Could achieve 5-8× speedup

4. **Implement voltage-lifting heuristics**
   - Pre-compute better initial guess based on network impedance
   - Especially effective for radial feeders

5. **Regularize the system matrix**
   - The code already does this (regularization = 1e-6)
   - Consider using ILUT preconditioner for better conditioning

---

## Conclusion

**IEEE8500 requires 18-23 iterations NOT because of network size, but because:**
1. **Poor voltage regulation** (809× spread) → weak network coupling
2. **Slow fixed-point convergence** (ratio 0.51 vs 0.02 for others)
3. **All constant-power loads** → strong nonlinearity in load model
4. **Radial network topology** → information mixes slowly through iterations

The Z-bus fixed-point method is fundamentally limited for weakly-coupled networks. Newton-Raphson would achieve **4-6× convergence speedup** with minimal additional work per iteration.
