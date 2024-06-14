#scope_file

#import "File_Utilities";
#import "Hash";
#import "Hash_Table";
#import "Pool";
#import "System";
#import "Thread";

Simp :: #import "Simp";

album_art_creation_thread_group: Thread_Group;

pool: Pool;

Album_Art_Job_Info :: struct {
    cover_path        : string;
    thumbnail_path    : string;
    library_album_ptr : *Album;

    create_thumbnail         : bool = false;
    thumbnail_width          : s32;
    create_thumbnail_success : bool;

    create_display_art         : bool = false;
    display_art_path           : string;
    display_art_width          : s32;
    create_display_art_success : bool;

    artist_name            : string;
    album_name             : string;
    load_thumbnail_success : bool;
}

REMAINING_ALBUM_ART_JOBS := 0;

log_data :: Log_Data.{"album_art_thread", false};

#scope_module

start_album_art_creation_thread_group :: (albums: [] *Album) {

    context.logger_data = *log_data;

    if !directory_exists(config.album_cover_directory) {
        log("Album cover directory doesn't exist at '%', skipping album art + thumbnail creation", config.album_cover_directory, flags=.ERROR);
        return;
    }

    init_thread_group :: (num_jobs: s32) {
        num_cpus := get_number_of_processors();
        #if (OS == .WINDOWS) || (OS == .LINUX) {
            // This routine reports hyperthreads, so, divide by two, because of Intel marketing.
            num_cpus /= 2;
        }
        num_threads := min(num_jobs, max(num_cpus - 1, 1));
        plural_cpus := ifx num_cpus != 1 then "s" else "";
        plural_jobs := ifx num_jobs != 1 then "s" else "";
        log("This machine reports % CPU% for % job%; starting % threads.", num_cpus, plural_cpus, num_jobs, plural_jobs, num_threads, flags=.VERY_VERBOSE_ONLY);

        init(*album_art_creation_thread_group, num_threads, thread_proc);

        album_art_creation_thread_group.name = "Create album art thumbnails";
        album_art_creation_thread_group.logging = false;
    }

    thread_proc :: (group: *Thread_Group, thread: *Thread, work: *void) -> Thread_Continue_Status {
        context.logger_data = *log_data;
        context.allocator = group.allocator;

        job_info := cast(*Album_Art_Job_Info) work;

        /************************************************************
        * create missing thumbnail and/or large display art bitmaps *
        ************************************************************/

        if job_info.create_thumbnail || job_info.create_display_art {
            log("Attempting to load cover at path %", job_info.cover_path, flags=.VERY_VERBOSE_ONLY);

            bitmap: Simp.Bitmap;
            if !Simp.bitmap_load(*bitmap, job_info.cover_path) {
                log("Failed to load album art file %", job_info.cover_path, flags=.ERROR);
                return .CONTINUE;
            }
            defer Simp.deinit(*bitmap);

            if job_info.create_thumbnail {
                width := job_info.thumbnail_width;
                if !Simp.bitmap_resize_and_save(*bitmap, job_info.thumbnail_path, width, cast(s32)(bitmap.height * cast(float64)width / bitmap.width)) {
                    log("Failed to convert cover % to thumbnail at %", job_info.cover_path, job_info.thumbnail_path);
                    job_info.create_thumbnail_success = false;
                } else {
                    job_info.create_thumbnail_success = true;
                }
            }
            if job_info.create_display_art {
                width := job_info.display_art_width;
                if !Simp.bitmap_resize_and_save(*bitmap, job_info.display_art_path, width, cast(s32)(bitmap.height * cast(float64)width / bitmap.width)) {
                    log("Failed to convert cover % to display art bitmap at %", job_info.cover_path, job_info.display_art_path);
                    job_info.create_display_art_success = false;
                } else {
                    job_info.create_display_art_success = true;
                }
            }
        }

        return .CONTINUE;
    }

    #if DEBUG_BUILD  pool.overwrite_memory = true;
    thread_proc_context: Context;
    thread_proc_context.allocator.proc = pool_allocator_proc;
    thread_proc_context.allocator.data = *pool;
    if !album_art_creation_thread_group.initted {
        set_allocators(*pool);
    }

    work_list: [..] *Album_Art_Job_Info;

    num_thumbnails_attempting_to_create := 0;
    push_context thread_proc_context {
         // find all albums that don't have a thumbnail but do have a cover we can use to create one
        for album: albums {
            if album.cover_path && file_exists(album.cover_path) {
                album_hash       := get_hash(tprint("%-%", album.artist_name, album.name));
                thumbnail_path   := tprint("%/%-%x.bmp", config.album_cover_directory, album_hash, THUMBNAIL_WIDTH);
                display_art_path := tprint("%/%-%x.bmp", config.album_cover_directory, album_hash, LARGE_ALBUM_ART_WIDTH);

                work := New(Album_Art_Job_Info);
                work.artist_name       = copy_string(album.artist_name);
                work.album_name        = copy_string(album.name);
                work.cover_path        = copy_string(album.cover_path);
                work.thumbnail_path    = copy_string(thumbnail_path);
                work.library_album_ptr = album;

                if !file_exists(thumbnail_path) {
                    work.create_thumbnail = true;
                    work.thumbnail_width  = THUMBNAIL_WIDTH;
                }
                if !file_exists(display_art_path) {
                    work.create_display_art = true;
                    work.display_art_path   = copy_string(display_art_path);
                    work.display_art_width  = LARGE_ALBUM_ART_WIDTH;
                }

                array_add(*work_list, work);
            }
        }
    }

    if work_list.count > 0 { // only start threads if we have any work to do
        if !album_art_creation_thread_group.initted {
            init_thread_group(cast(s32)work_list.count);
            start(*album_art_creation_thread_group);
        }

        for work_list {
            add_work(*album_art_creation_thread_group, it, tprint("Work item to create thumbnail from cover at %", it.cover_path));
        }
    }
    REMAINING_ALBUM_ART_JOBS = work_list.count;
    array_free(work_list);
}

// start_album_art_creation_on_main_thread :: (albums: [] *Album) {

//     context.logger_data = *log_data;

//     if !directory_exists(config.album_cover_directory) {
//         log("Album cover directory doesn't exist at '%', skipping album art + thumbnail creation", config.album_cover_directory, flags=.ERROR);
//         return;
//     }

//     work_list: [..] *Album_Art_Job_Info;

//     // find all albums that don't have a thumbnail but do have a cover we can use to create one
//     for album: albums {
//         if album.cover_path && file_exists(album.cover_path) {
//             album_hash       := get_hash(tprint("%-%", album.artist_name, album.name));
//             thumbnail_path   := tprint("%/%-%x.bmp", config.album_cover_directory, album_hash, THUMBNAIL_WIDTH);
//             display_art_path := tprint("%/%-%x.bmp", config.album_cover_directory, album_hash, LARGE_ALBUM_ART_WIDTH);

//             work := New(Album_Art_Job_Info);
//             work.artist_name       = copy_string(album.artist_name);
//             work.album_name        = copy_string(album.name);
//             work.cover_path        = copy_string(album.cover_path);
//             work.thumbnail_path    = copy_string(thumbnail_path);
//             work.library_album_ptr = album;

//             if !file_exists(thumbnail_path) {
//                 work.create_thumbnail = true;
//                 work.thumbnail_width  = THUMBNAIL_WIDTH;
//             }
//             if !file_exists(display_art_path) {
//                 work.create_display_art = true;
//                 work.display_art_path   = copy_string(display_art_path);
//                 work.display_art_width  = LARGE_ALBUM_ART_WIDTH;
//             }

//             array_add(*work_list, work);
//         }
//     }
//     defer array_free(work_list);
//     REMAINING_ALBUM_ART_JOBS = work_list.count;

//     for job_info: work_list {
//         /************************************************************
//         * create missing thumbnail and/or large display art bitmaps *
//         ************************************************************/

//         if job_info.create_thumbnail || job_info.create_display_art {
//             log("Attempting to load cover at path %", job_info.cover_path, flags=.VERY_VERBOSE_ONLY);

//             bitmap: Simp.Bitmap;
//             defer Simp.deinit(*bitmap);
//             if !Simp.bitmap_load(*bitmap, job_info.cover_path) {
//                 log("Failed to load album art file %", job_info.cover_path, flags=.ERROR);
//                 continue;
//             }

//             resize_and_save_bitmap :: (bitmap: *Simp.Bitmap, output_path: string, width: s32) -> bool {
//                 resized_bitmap := New(Simp.Bitmap);
//                 if !Simp.bitmap_resize(bitmap, width, cast(s32)(bitmap.height * cast(float64)width / bitmap.width), resized_bitmap) {
//                     log("Failed to resize bitmap", flags=.ERROR);
//                     return false;
//                 }
//                 defer { Simp.deinit(resized_bitmap); free(resized_bitmap); };

//                 if !Simp.bitmap_save(resized_bitmap, output_path) {
//                     log("Failed to save resized album art bitmap to '%'", output_path, flags=.ERROR);
//                     return false;
//                 }

//                 log("Saved resized album art bitmap to '%'", output_path, flags=.VERY_VERBOSE_ONLY);

//                 return true;
//             }

//             if job_info.create_thumbnail {
//                 if !resize_and_save_bitmap(*bitmap, job_info.thumbnail_path, job_info.thumbnail_width) {
//                     log("Failed to convert cover % to thumbnail at %", job_info.cover_path, job_info.thumbnail_path);
//                     job_info.create_thumbnail_success = false;
//                 } else {
//                     job_info.create_thumbnail_success = true;
//                 }
//             }
//             if job_info.create_display_art {
//                 if !resize_and_save_bitmap(*bitmap, job_info.display_art_path, job_info.display_art_width) {
//                     log("Failed to convert cover % to display art bitmap at %", job_info.cover_path, job_info.display_art_path);
//                     job_info.create_display_art_success = false;
//                 } else {
//                     job_info.create_display_art_success = true;
//                 }
//             }
//         }
//     }
// }

check_album_art_creation_jobs :: () {

    context.logger_data = *log_data;

    if REMAINING_ALBUM_ART_JOBS > 0 {
        results := get_completed_work(*album_art_creation_thread_group);
        if results.count > 0 {
            create_thumbnail_successes,   create_thumbnail_failures   := 0;
            create_display_art_successes, create_display_art_failures := 0;
            load_thumbnail_successes,     load_thumbnail_failures     := 0;
            for results {
                job_info := cast(*Album_Art_Job_Info) it;

                if job_info.create_thumbnail
                    if job_info.create_thumbnail_success create_thumbnail_successes += 1;
                    else                                 create_thumbnail_failures  += 1;

                if job_info.create_display_art
                    if job_info.create_display_art_success create_display_art_successes += 1;
                    else                                   create_display_art_failures  += 1;

                if job_info.load_thumbnail_success load_thumbnail_successes += 1;
                else                               load_thumbnail_failures  += 1;
            }

            REMAINING_ALBUM_ART_JOBS -= results.count;
            log("create thumbnail jobs finished: % successes, % failures", create_thumbnail_successes, create_thumbnail_failures, flags=.VERY_VERBOSE_ONLY);
            log("create display art jobs finished: % successes, % failures", create_display_art_successes, create_display_art_failures, flags=.VERY_VERBOSE_ONLY);
            log("load thumbnail jobs finished: % successes, % failures", load_thumbnail_successes, load_thumbnail_failures, flags=.VERY_VERBOSE_ONLY);
            log("% remaining cover jobs", REMAINING_ALBUM_ART_JOBS, flags=.VERBOSE_ONLY);
            if REMAINING_ALBUM_ART_JOBS == 0 {
                reset(*pool);

                // #if DEBUG_BUILD {
                //     log("============ DONE ===============\n");
                //     log_leak_report(make_leak_report());
                //     log("============ DONE ===============\n");
                // }

                // shutdown(*album_art_creation_thread_group);
            }
        }
    }
}
