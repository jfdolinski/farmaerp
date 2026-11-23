import { Controller, Get, Headers, Inject, Param, Res, UseGuards } from '@nestjs/common';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { requireUuid } from '../common/parse.js';
import { DatabaseService, DbClient } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

export interface CatalogImage {
  id: string;
  catalog_product_id: string;
  sort_order: number;
  is_main: boolean;
  width: number;
  height: number;
  sha256: string;
}

/** Imagens dos produtos do Catálogo informados, sem o conteúdo. */
export async function catalogImages(client: DbClient, catalogIds: (string | null)[]): Promise<CatalogImage[]> {
  const ids = [...new Set(catalogIds.filter((id): id is string => Boolean(id)))];
  if (ids.length === 0) return [];
  const { rows } = await client.query<CatalogImage>('SELECT * FROM app.catalog_images($1)', [ids]);
  return rows;
}

/** Acrescenta a imagem principal (id) a cada linha que tem produto do Catálogo. */
export async function withMainImage<T extends Record<string, unknown>>(
  client: DbClient,
  rows: T[],
  catalogField: string,
): Promise<(T & { main_image_id: string | null })[]> {
  const images = await catalogImages(client, rows.map((row) => row[catalogField] as string | null));
  const main = new Map(images.filter((image) => image.is_main).map((image) => [image.catalog_product_id, image.id]));
  return rows.map((row) => ({ ...row, main_image_id: main.get(row[catalogField] as string) ?? null }));
}

/** Entrega a imagem. Como o conteúdo não muda (outra imagem é outro id), o cache é longo. */
@Controller('admin')
@UseGuards(SessionGuard)
export class CatalogImagesController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get('catalog-images/:id/:size')
  async image(
    @Param('id') id: string,
    @Param('size') size: string,
    @Headers('if-none-match') ifNoneMatch: string | undefined,
    @Res() res: Response,
  ) {
    const imageId = requireUuid(id);
    if (size !== 'full' && size !== 'thumb') throw new AppError('FA005');
    const row = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ content: Buffer; sha256: string }>(
        'SELECT * FROM app.catalog_image_content($1, $2)',
        [imageId, size],
      );
      return rows[0];
    });
    if (!row) throw new AppError('FA006');
    const etag = `"${row.sha256}-${size}"`;
    res.setHeader('ETag', etag);
    res.setHeader('Cache-Control', 'private, max-age=31536000, immutable');
    if (ifNoneMatch === etag) {
      res.status(304).end();
      return;
    }
    res.setHeader('Content-Type', 'image/webp');
    res.setHeader('Content-Length', String(row.content.length));
    res.end(row.content);
  }
}
