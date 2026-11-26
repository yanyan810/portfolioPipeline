@{
    output = @{
        zip_name = 'SampleSubmission'
        generated_dir = '.\Generated'
        project_folder_name = 'SourceCode'
        executable_folder_name = 'Executable'
    }
    works = @(
        @{
            work_folder_name = '01_SampleWork'
            local_source_path = '.\examples\SampleWork'
            smoke_test_required = $false
            exclude_patterns = @('*.tmp')
        }
    )
}
