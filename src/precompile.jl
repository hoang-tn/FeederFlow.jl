using PrecompileTools

@setup_workload begin
    @compile_workload begin
        balanced_slack()
    end
end
