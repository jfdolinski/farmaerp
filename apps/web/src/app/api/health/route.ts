// Verificação de saúde do contêiner: confere só se a retaguarda está no ar.
export function GET() {
  return Response.json({ status: "ok" });
}
