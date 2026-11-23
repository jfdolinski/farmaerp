import styles from "../terminais/page.module.css";

export interface ProductImage {
  id: string;
  is_main: boolean;
  width: number;
  height: number;
}

/** Miniatura da imagem do Catálogo, ou um espaço neutro quando não há. */
export function CatalogThumb({ id, alt, size = 48 }: { id: string | null; alt: string; size?: number }) {
  if (!id) {
    return (
      <span className={styles.noImage} style={{ width: size, height: size }} aria-hidden="true">
        Sem imagem
      </span>
    );
  }
  return (
    // As imagens passam pela rota /imagens, com a sessão: o otimizador do Next não teria a sessão.
    // eslint-disable-next-line @next/next/no-img-element
    <img className={styles.thumb} src={`/imagens/${id}/thumb`} alt={alt} width={size} height={size} loading="lazy" />
  );
}

/** Imagem principal grande e as outras em miniatura, que abrem no tamanho maior. */
export function ProductGallery({ images, name }: { images: ProductImage[]; name: string }) {
  if (images.length === 0) {
    return <CatalogThumb id={null} alt={name} size={160} />;
  }
  const main = images.find((image) => image.is_main) ?? images[0];
  const others = images.filter((image) => image.id !== main.id);
  return (
    <div className={styles.gallery}>
      <a href={`/imagens/${main.id}/full`} target="_blank" rel="noopener">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          className={styles.mainImage}
          src={`/imagens/${main.id}/full`}
          alt={name}
          width={main.width}
          height={main.height}
        />
      </a>
      {others.length > 0 && (
        <div className={styles.inline}>
          {others.map((image, index) => (
            <a key={image.id} href={`/imagens/${image.id}/full`} target="_blank" rel="noopener">
              <CatalogThumb id={image.id} alt={`${name}, imagem ${index + 2}`} size={64} />
            </a>
          ))}
        </div>
      )}
    </div>
  );
}
