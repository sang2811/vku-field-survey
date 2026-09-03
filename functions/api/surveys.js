export async function onRequestPost(context) {
  const payload = await context.request.json();

  return Response.json({
    ok: true,
    receivedAt: new Date().toISOString(),
    surveyId: payload.id || null
  });
}

export async function onRequestGet() {
  return Response.json({
    ok: true,
    service: 'VKU Field Survey API'
  });
}
