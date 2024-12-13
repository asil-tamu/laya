import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:laya/config/schema/series.dart';
import 'package:laya/config/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class SeriesRepository {
  static const String _tableName = 'series';
  static const String _storageBucket = 'series_thumbnails';
  final int currentYear = DateTime.now().year;

  // Get all the series created by a user
  Future<List<Series>> getUserSeries(String userID) async {
    try {
      final response = await supabase
          .from('series')
          .select()
          .eq('creator_id', userID)
          .order('created_at', ascending: false);

      final seriesList = (response)
          .map(
            (json) => Series.fromJson(json),
          )
          .toList();

      return seriesList;
    } catch (error) {
      throw 'Failed to fetch all the series created by the user';
    }
  }

  // Get a specific series by ID
  Future<Series> getSeries(String seriesID) async {
    try {
      final response = await supabase
          .from(_tableName)
          .select()
          .eq(
            'id',
            seriesID,
          )
          .single();

      final series = Series.fromJson(response);

      return series;
    } catch (error) {
      throw 'Failed to load the series. Please try again';
    }
  }

  // Create the image file name
  String createFileName({
    required String filePath,
    required String creatorId,
    required String title,
  }) {
    final sanitizedTitle = title
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final fileExt = path.extension(filePath).toLowerCase();
    final validExtensions = ['.jpg', '.jpeg', '.png'];

    if (!validExtensions.contains(fileExt)) {
      throw 'Invalid file type. Only JPG and PNG files are allowed.';
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomId = const Uuid().v4().substring(0, 8);
    final fileName =
        "${sanitizedTitle}_${creatorId}_${timestamp}_$randomId$fileExt";

    return fileName;
  }

  // Upload the cover image
  Future<String> uploadCoverImage({
    required File file,
    required String creatorId,
    required String title,
  }) async {
    final fileName = createFileName(
      filePath: file.path,
      creatorId: creatorId,
      title: title,
    );

    try {
      await supabase.storage.from('series_covers').upload(fileName, file);

      final publicUrl =
          supabase.storage.from('series_covers').getPublicUrl(fileName);

      return publicUrl;
    } catch (error) {
      throw 'Failed to upload the cover image. Please try again';
    }
  }

  // Upload the thumbnail
  Future<String> uploadThumbnail({
    required File file,
    required String creatorId,
    required String title,
  }) async {
    final fileName = createFileName(
      filePath: file.path,
      creatorId: creatorId,
      title: title,
    );

    try {
      await supabase.storage.from('series_thumbnail').upload(fileName, file);

      final publicUrl =
          supabase.storage.from('series_thumbnail').getPublicUrl(fileName);

      return publicUrl;
    } catch (error) {
      throw 'Failed to upload the thumbnail. Please try again';
    }
  }

  // Create a new series
  Future<Series> createSeries({
    required String creatorId,
    required String categoryId,
    required String description,
    required String title,
    required File coverImageFile,
    required File thumbnailFile,
  }) async {
    try {
      String coverImageUrl = await uploadCoverImage(
        file: coverImageFile,
        creatorId: creatorId,
        title: title,
      );

      String thumbnailUrl = await uploadThumbnail(
        file: thumbnailFile,
        creatorId: creatorId,
        title: title,
      );

      final response = await supabase
          .from(_tableName)
          .insert({
            'creator_id': creatorId,
            'category_id': categoryId,
            'description': description,
            'title': title,
            'cover_image_url': coverImageUrl,
            'thumbnail_url': thumbnailUrl,
          })
          .select()
          .single();

      return Series.fromJson(response);
    } catch (e) {
      throw 'Failed to create series. Please try again';
    }
  }

  // Update an existing series
  Future<Series> updateSeries({
    required String seriesId,
    String? categoryId,
    String? creatorId,
    String? description,
    String? title,
    File? newCoverImage,
    File? newThumbnail,
  }) async {
    try {
      final updates = <String, dynamic>{};

      if (title != null) updates['title'] = title;
      if (description != null) updates['description'] = description;
      if (categoryId != null) updates['category_id'] = categoryId;

      if (newCoverImage != null && creatorId != null) {
        // Delete old cover image if exists
        final series = await getSeries(seriesId);
        if (series.coverImageUrl.isNotEmpty) {
          await _deleteCoverImage(series.coverImageUrl);
        }

        // Upload new cover image
        updates['cover_image_url'] = await uploadCoverImage(
          file: newCoverImage,
          creatorId: creatorId,
          title: title ?? series.title,
        );
      }

      if (newThumbnail != null && creatorId != null) {
        // Delete old thumbnail if exists
        final series = await getSeries(seriesId);
        if (series.thumbnailUrl.isNotEmpty) {
          await _deleteThumbnail(series.thumbnailUrl);
        }

        // Upload new thumbnail
        updates['thumbnail_url'] = await uploadThumbnail(
          file: newThumbnail,
          creatorId: creatorId,
          title: title ?? series.title,
        );
      }

      if (updates.isEmpty) throw 'No updates provided';

      final response = await supabase
          .from(_tableName)
          .update(updates)
          .eq('id', seriesId)
          .select()
          .single();

      return Series.fromJson(response);
    } catch (e) {
      throw 'Failed to update series: $e';
    }
  }

  /// Delete a series and its thumbnail
  Future<void> deleteSeries(Series series) async {
    try {
      // Delete thumbnail from storage if exists
      final thumbnailFileName = series.thumbnailUrl.split('/').last;
      await supabase.storage
          .from('series_thumbnails')
          .remove([thumbnailFileName]);

      // Delete cover image from storage if exists
      final coverImageFileName = series.coverImageUrl.split('/').last;
      await supabase.storage.from('series_covers').remove([coverImageFileName]);

      // Delete series from database
      await supabase.from('series').delete().eq('id', series.id);
    } on StorageException catch (e) {
      throw 'Failed to delete series thumbnail: ${e.message}';
    } catch (e) {
      throw 'Failed to delete series: $e';
    }
  }

  // Search series by title
  Future<List<Series>> searchSeries(String query) async {
    try {
      final response = await supabase
          .from(_tableName)
          .select()
          .ilike('title', '%$query%')
          .order('created_at', ascending: false);

      return (response as List).map((json) => Series.fromJson(json)).toList();
    } catch (e) {
      throw 'Failed to search series';
    }
  }

  // Get series with content count
  Future<List<Map<String, dynamic>>> getSeriesWithContentCount(
    String userId,
  ) async {
    try {
      final response = await supabase
          .from(_tableName)
          .select('*, content:content(count)')
          .eq('creator_id', userId)
          .order('created_at', ascending: false);

      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw 'Failed to load series with content count';
    }
  }

  Future<void> _deleteThumbnail(String thumbnailUrl) async {
    try {
      final fileName = path.basename(thumbnailUrl);
      await supabase.storage.from(_storageBucket).remove([fileName]);
    } catch (e) {
      throw 'Failed to delete thumbnail';
    }
  }

  Future<void> _deleteCoverImage(String coverImageUrl) async {
    try {
      final fileName = path.basename(coverImageUrl);
      await supabase.storage.from('series_covers').remove([fileName]);
    } catch (e) {
      throw 'Failed to delete thumbnail';
    }
  }

  Future<List<Series>> getRecentlyAddedSeries() async {
    try {
      final response = await supabase
          .from(_tableName)
          .select()
          .order('created_at', ascending: false)
          .limit(10);

      return (response as List).map((json) => Series.fromJson(json)).toList();
    } catch (e) {
      throw 'Failed to load recently added series';
    }
  }
}