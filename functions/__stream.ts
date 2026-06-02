import { handleStreamRequest } from "./_stream-proxy"

export const onRequest: PagesFunction = async (context) => {
  return handleStreamRequest(context.request)
}
