using Test
using FeederFlow
using LinearAlgebra

const LINE_SANITY_CASES = (
    ("IEEE13", IEEE13_DSS),
    ("IEEE37", IEEE37_DSS),
    ("IEEE123", IEEE123_DSS),
    ("IEEE240", IEEE240_DSS),
    ("IEEE906", IEEE906_DSS),
)

@testset "Line admittance sanity checks" begin
    @testset "Line admittance matrix properties" begin
        for (network_name, dss_path) in LINE_SANITY_CASES
            @testset "$network_name" begin
                network = FeederFlow.parse_file(dss_path)

                for line in network.lines
                    # Skip switches (they have negligible length/impedance)
                    line.is_switch && continue

                    yseries, yshunt = FeederFlow.line_admittance(line; include_shunt = true, ybase = network.base.Ybase)

                    @testset "Line $(line.name)" begin
                        # Series admittance should be symmetric (may have small numerical errors from matrix inversion)
                        @test yseries ≈ transpose(yseries) atol = 1e-6 * maximum(abs.(yseries))

                        # Series admittance diagonal should have positive real part
                        # (since series impedance has positive resistance)
                        for i in 1:size(yseries, 1)
                            @test real(yseries[i, i]) > 0
                        end

                        # Shunt admittance should be symmetric (capacitance matrix is symmetric)
                        if maximum(abs.(yshunt)) > 1e-12
                            @test yshunt ≈ transpose(yshunt) atol = 1e-6 * maximum(abs.(yshunt))
                        end

                        # Shunt admittance diagonal should have non-negative imaginary part
                        # (capacitive susceptance is positive or zero)
                        for i in 1:size(yshunt, 1)
                            @test imag(yshunt[i, i]) >= -1e-12
                        end

                        # Admittance magnitudes should be reasonable (not NaN/Inf)
                        @test all(isfinite, yseries)
                        @test all(isfinite, yshunt)
                    end
                end
            end
        end
    end
    
    @testset "Linecode parsing - sequence parameters" begin
        # Test that sequence parameters are correctly converted to phase matrices
        # For a balanced 3-phase line: Z_phase = [z_s z_m z_m; z_m z_s z_m; z_m z_m z_s]
        # where z_s = (z0 + 2*z1)/3 and z_m = (z0 - z1)/3
        
        z1 = complex(0.1, 0.5)  # positive sequence impedance
        z0 = complex(0.3, 1.5)  # zero sequence impedance
        
        zmat = FeederFlow.sequence_to_phase_matrix(z1, z0)
        
        # Self impedance: (z0 + 2*z1)/3
        z_self = (z0 + 2*z1) / 3
        # Mutual impedance: (z0 - z1)/3
        z_mutual = (z0 - z1) / 3
        
        @test zmat[1, 1] ≈ z_self atol=1e-12
        @test zmat[2, 2] ≈ z_self atol=1e-12
        @test zmat[3, 3] ≈ z_self atol=1e-12
        @test zmat[1, 2] ≈ z_mutual atol=1e-12
        @test zmat[1, 3] ≈ z_mutual atol=1e-12
        @test zmat[2, 3] ≈ z_mutual atol=1e-12
        
        # Matrix should be symmetric
        @test zmat ≈ transpose(zmat) atol=1e-12
    end
    
    @testset "LineCode extended properties" begin
        for (network_name, dss_path) in LINE_SANITY_CASES
            @testset "$network_name" begin
                network = FeederFlow.parse_file(dss_path)

                # Verify linecodes have expected properties
                for (_, lc) in pairs(network.linecodes)
                    @test lc.nphases > 0
                    @test lc.basefreq > 0
                    @test lc.normamps >= 0
                    @test lc.emergamps >= 0
                    @test lc.units isa String
                    @test lc.basefreq isa Float64

                    # Matrices should be square with correct size
                    @test size(lc.rmatrix) == (lc.nphases, lc.nphases)
                    @test size(lc.xmatrix) == (lc.nphases, lc.nphases)
                    @test size(lc.cmatrix) == (lc.nphases, lc.nphases)

                    # Resistance should be non-negative on diagonal
                    for i in 1:lc.nphases
                        @test lc.rmatrix[i, i] >= 0
                    end
                end
            end
        end
    end
    
    @testset "LineDevice basefreq propagated from linecode" begin
        for (network_name, dss_path) in LINE_SANITY_CASES
            @testset "$network_name" begin
                network = FeederFlow.parse_file(dss_path)
                for line in network.lines
                    @test line.basefreq > 0
                    @test line.basefreq isa Float64
                    if line.linecode_name !== nothing
                        lc = network.linecodes[line.linecode_name]
                        @test line.basefreq == lc.basefreq
                    end
                end
            end
        end
    end
    
    @testset "unit_to_kft warns on unknown units" begin
        @test_logs (:warn, r"Unknown DSS length unit") FeederFlow.unit_to_kft("bogus")
    end
    
    @testset "Unit conversion factors" begin
        # Test unit conversion helper
        @test FeederFlow.unit_to_kft("none") == 1.0
        @test FeederFlow.unit_to_kft("kft") == 1.0
        @test FeederFlow.unit_to_kft("mi") ≈ 5.28 atol=1e-6
        @test FeederFlow.unit_to_kft("km") ≈ 3.28084 atol=1e-4
        @test FeederFlow.unit_to_kft("ft") ≈ 0.001 atol=1e-8
        @test FeederFlow.unit_to_kft("m") ≈ 0.00328084 atol=1e-7
    end
end
