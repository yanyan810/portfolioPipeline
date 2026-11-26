@{
    output = @{
        zip_name = 'LE3B_24_MIYAZAWA_HARUHI_WORK'
        generated_dir = '.\Generated'
        project_folder_name = 'SourceCode'
        executable_folder_name = 'Executable'
    }
    works = @(
        @{
            work_folder_name = '01_anAlive'
            git_repository_url = 'https://github.com/yanyan810/anAlive.git'
            google_drive_file_id = '19dp1DcmRzcpZ2S7Nnt5uo6nKK_sSvMdAv3TW24JNSdo'
            project_msbuild_target_path = 'CG2_Setup.sln'
            project_msbuild_configuration = 'Release'
            project_msbuild_platform = 'x64'
            project_build_copy_list = @(
                '.pipeline_build\Output\CG2_Setup.exe'
                '.pipeline_build\Output\dxcompiler.dll'
                '.pipeline_build\Output\dxil.dll'
                'resources'
            )
            test_executable_name = 'CG2_Setup.exe'
            smoke_test_required = $true
            smoke_test_wait_seconds = 5
            exclude_patterns = @('*.tmp', '*.log', '*.vcxproj.user', '.pipeline_build', 'muzzle*backup*')
        }
    )
}
